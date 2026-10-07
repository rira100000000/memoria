module MemoriaServer
  # キャラクターにツールや振る舞いを足す拡張の基底クラス。
  #
  # 記憶バックエンド（Adapter）が「記憶と応答生成」を、Capability が「出力の形式」を
  # 差し替えるのに対し、Plugin は「キャラクターが使えるツール」と「追加の指示」を足す。
  # 秘書・作業依頼のような個人的な用途は、リポジトリの外に置いたプラグインで実現する。
  #
  # 場面（scene）は2つ：
  #   - :chat     マスターとの会話中（マスターの依頼に応えて動く）
  #   - :thinking 思考ループ（キャラが自分の意思で動く）
  # 危ないツールは :chat だけに出す、のように場面ごとに出し分けられる。
  #
  # 書き方は docs/PLUGIN_README.md を参照。
  class Plugin
    # ツールの引数は JSON Schema（type は小文字 "object" / "string" ...）で書く。
    # LLMごとの形式（Gemini の大文字 type など）への変換は memoria が行う。

    # @return [Symbol] プラグインの識別子
    def name
      raise NotImplementedError, "#{self.class}#name"
    end

    # @param character [Character]
    # @return [Boolean] このキャラクターで有効か
    def enabled_for?(_character)
      true
    end

    # @param scene [Symbol] :chat / :thinking
    # @param platform [Symbol, nil] 会話の経路（:discord, :api など。:thinking では nil）
    # @return [Array<Hash>] { name:, description:, parameters: } の配列
    def tools(scene:, platform: nil)
      []
    end

    # @return [Hash] ツールの実行結果（LLMに返す）。:log キーを含めると会話ログに記録される
    def execute(tool_name, args, character:, scene:)
      { error: "#{name} does not implement #{tool_name}" }
    end

    # @return [String, nil] システムプロンプトの末尾に足す指示
    def prompt_segment(_character, scene:)
      nil
    end

    # --- プラグインから使える補助 ---

    # 連絡手段（Discord等）にそのまま送る。システムからのお知らせ向け
    def notify(character, text)
      ::MessageDispatcher.dispatch(character, text)
    end

    # キャラクターを今すぐ起こし、目的に沿って考えさせてからマスターに伝えさせる。
    # 長い作業が終わったときに、キャラ自身の言葉で報告させる用途。
    # 失敗しても予定の仕組みが通知する（action: "share"）。
    def wake(character, purpose:, remember: false)
      wakeup = character.scheduled_wakeups.create!(
        scheduled_at: Time.current,
        purpose: purpose,
        action: "share",
        status: "pending",
        origin: "self",
        remember: remember
      )
      wakeup.enqueue!
      wakeup
    end

    # --- Registry ---

    # サブクラスから MyPlugin.register(...) と呼んでも同じ登録先を使うよう、定数で持つ
    REGISTRY = {}

    class << self
      def register(plugin)
        raise ContractViolation, "plugin must inherit MemoriaServer::Plugin" unless plugin.is_a?(Plugin)
        REGISTRY[plugin.name.to_sym] = plugin
      end

      def unregister(name)
        REGISTRY.delete(name.to_sym)
      end

      def find(name)
        REGISTRY[name.to_s.to_sym]
      end

      def all
        REGISTRY.values
      end

      # キャラクターと場面に応じて有効なツールを集める
      # @return [Array<Array(Plugin, Hash)>] [プラグイン, ツール定義] の組
      def tools_for(character, scene:, platform: nil)
        all.select { |p| p.enabled_for?(character) }.flat_map { |plugin|
          plugin.tools(scene: scene, platform: platform).map { |tool| [plugin, tool] }
        }
      end

      # Gemini の functionDeclarations 形式に変換したツール定義
      def gemini_declarations(character, scene:, platform: nil)
        tools_for(character, scene: scene, platform: platform).map { |_, tool| ToolSchema.to_gemini(tool) }
      end

      # プラグインのツールなら実行して結果を返す。該当しなければ nil
      def execute(tool_name, args, character:, scene:, platform: nil)
        plugin, = tools_for(character, scene: scene, platform: platform)
          .find { |_, tool| tool[:name].to_s == tool_name.to_s }
        return nil unless plugin

        plugin.execute(tool_name.to_s, args || {}, character: character, scene: scene)
      rescue => e
        Rails.logger.error("[MemoriaServer::Plugin] #{plugin&.name}##{tool_name} failed: #{e.class}: #{e.message}")
        { error: "ツールの実行に失敗しました（#{e.class}: #{e.message.to_s.truncate(200)}）" }
      end

      def prompt_segments(character, scene:)
        all.select { |p| p.enabled_for?(character) }
          .filter_map { |p| p.prompt_segment(character, scene: scene).presence }
          .join("\n\n")
      end

      # MEMORIA_PLUGIN_PATHS（":" 区切りのディレクトリ）にある *.rb を読み込む。
      # 各ファイルは MemoriaServer::Plugin.register(...) で自分を登録する。
      # 読み込みに失敗したプラグインはログに残して飛ばす（キャラ全体を止めない）。
      def load_paths!(paths = ENV["MEMORIA_PLUGIN_PATHS"])
        paths.to_s.split(":").map(&:strip).reject(&:empty?).each do |dir|
          dir = File.expand_path(dir)
          unless Dir.exist?(dir)
            Rails.logger.error("[MemoriaServer::Plugin] plugin path not found: #{dir}")
            next
          end

          Dir.glob(File.join(dir, "*.rb")).sort.each do |file|
            require file
            Rails.logger.info("[MemoriaServer::Plugin] loaded #{file}")
          rescue Exception => e # rubocop:disable Lint/RescueException -- SyntaxError も拾ってサーバを止めない
            Rails.logger.error("[MemoriaServer::Plugin] failed to load #{file}: #{e.class}: #{e.message}")
          end
        end
      end
    end

    # ツール定義の形式変換
    module ToolSchema
      module_function

      # JSON Schema の type を Gemini の大文字表記に揃える（既に大文字ならそのまま）
      def to_gemini(tool)
        {
          name: tool[:name].to_s,
          description: tool[:description].to_s,
          parameters: upcase_types(tool[:parameters] || { type: "object", properties: {} }),
        }
      end

      def upcase_types(schema)
        case schema
        when Hash
          schema.each_with_object({}) do |(k, v), h|
            h[k.to_sym] = k.to_s == "type" && v.is_a?(String) ? v.upcase : upcase_types(v)
          end
        when Array
          schema.map { |v| upcase_types(v) }
        else
          schema
        end
      end
    end
  end
end
