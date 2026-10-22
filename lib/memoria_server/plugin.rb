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

    # キャラクターを決まった時刻に起こす、定期の起床の宣言。
    # memoria はジョブのプロセスの起動時に、宣言を予定（ScheduledWakeup）にそろえる（MemoriaServer::Routines）。
    # key で同じ予定を見分けるので、中身を変えても予定は増えない。宣言をやめた予定は取り消される。
    # @return [Array<Hash>] { key:, recurrence: (cron式), purpose:, action: (nil / "share"), remember: (Boolean) } の配列
    def routines(_character)
      []
    end

    # 予定の決まりの上書き。キーは MemoriaServer::Plugin::SCHEDULE_POLICY_DEFAULTS を参照
    # @return [Hash]
    def schedule_policy(_character)
      {}
    end

    # --- プラグインから使える補助 ---

    # キャラクターの記憶から、query に関係するものを思い出す（アダプタの recall）
    # @return [String, nil]
    def recall(character, query)
      ::MemoriaServer.adapter.recall(character_id: character.id, query: query)
    end

    # text をキャラクターの記憶として残す（アダプタの memorize）
    def memorize(character, text, source:, metadata: {})
      ::MemoriaServer.adapter.memorize(character_id: character.id, text: text, source: source, metadata: metadata)
    end

    # 別のキャラクターに話しかけ、返答を受け取る（アダプタの respond）。
    # 話した内容は、そのキャラクターの会話として、そのキャラクターの記憶に残る
    # @param channel [String] 会話の場所（例: "読書: 夏目漱石『こころ』"）
    # @return [String] 返答。区切られたメッセージは空行でつなぐ
    def talk_to(character, text, channel:)
      context = { character_id: character.id, character_name: character.name, channel: channel, platform: name.to_sym,
                  current_input: text, history: [], client_metadata: {}, x_memoria: {} }
      messages = [+""]
      ::MemoriaServer.adapter.respond(text, context: context).each do |chunk|
        if chunk[:delta]
          messages.last << chunk[:delta]
        elsif chunk[:message_break]
          messages << +""
        end
      end
      messages.map(&:strip).reject(&:empty?).join("\n\n")
    end

    # このプラグインがキャラクターごとに持つ設定（Character#plugin_settings の、プラグインの name の欄）
    # @return [Hash]
    def settings(character)
      character.plugin_settings.to_h.fetch(name.to_s, {}).to_h
    end

    def save_settings(character, values)
      character.update!(plugin_settings: character.plugin_settings.to_h.merge(name.to_s => values))
    end

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

    # 予定の決まりの既定値
    #   self_recurring_needs_approval: キャラが自分で入れた繰り返しの予定を、ユーザーの承認まで動かさない
    SCHEDULE_POLICY_DEFAULTS = {
      self_recurring_needs_approval: true,
    }.freeze

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

      # @return [Array<Array(Plugin, Hash)>] [プラグイン, 定期の起床の宣言] の組
      def routines_for(character)
        all.select { |p| p.enabled_for?(character) }.flat_map { |plugin|
          plugin.routines(character).map { |routine| [plugin, routine] }
        }
      end

      # 既定値に、有効なプラグインの上書きを順に重ねる
      def schedule_policy(character)
        all.select { |p| p.enabled_for?(character) }
          .reduce(SCHEDULE_POLICY_DEFAULTS) { |policy, p| policy.merge(p.schedule_policy(character).to_h.symbolize_keys.slice(*SCHEDULE_POLICY_DEFAULTS.keys)) }
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

      # Gemini 形式（type が大文字）のツール定義を JSON Schema（MCP 用）に戻す
      def gemini_to_json_schema(declaration)
        {
          name: declaration[:name].to_s,
          description: declaration[:description].to_s,
          inputSchema: downcase_types(declaration[:parameters] || { type: "object", properties: {} }),
        }
      end

      def upcase_types(schema)
        convert_types(schema, &:upcase)
      end

      def downcase_types(schema)
        convert_types(schema, &:downcase)
      end

      def convert_types(schema, &conv)
        case schema
        when Hash
          schema.each_with_object({}) do |(k, v), h|
            h[k.to_sym] = k.to_s == "type" && v.is_a?(String) ? conv.call(v) : convert_types(v, &conv)
          end
        when Array
          schema.map { |v| convert_types(v, &conv) }
        else
          schema
        end
      end
    end
  end
end
