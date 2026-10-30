module ClaudeCli
  # MCP サーバ（bin/memoria_mcp）に渡すツールの出どころ。
  # 会話は ChatSession の、思考ループは Thinker のツールをそのまま使う（Gemini の場合と同じツールと実行処理）。
  # long_think_path を渡すと、長考の宣言（ClaudeCli::LongThink）のツールを足す
  module ToolProvider
    # @param record_id [Integer, nil] 会話の場面で、この会話の記録に結びつける（常駐の claude は、起動時の記録のまま長く動くため）。
    #   nil なら、そのときの有効な会話に結びつく
    def self.build(character:, scene:, platform: nil, trigger_type: nil, long_think_path: nil, record_id: nil, route_path: nil)
      provider =
        case scene.to_sym
        when :thinking then Thinking.new(character, trigger_type: trigger_type || "thinking_loop")
        when :chat then route_path ? RoutedChat.new(character, record_id: record_id, route_path: route_path) : Chat.new(character, platform: platform&.to_sym, record_id: record_id)
        else raise ArgumentError, "unknown scene: #{scene}"
        end
      long_think_path ? LongThink::Provider.new(provider, LongThink.new(long_think_path)) : provider
    end

    class Thinking
      def initialize(character, trigger_type:)
        @character = character
        @core = MemoriaCore::Core.new(character.vault_path)
        @health = ::Thinking::ThoughtHealthMonitor.report(@core)
        @llm_client = LlmClient.new(usage_tracker: usage_tracker(trigger_type))
      end

      def tools
        ::Thinking::Thinker.tool_definitions(@character).flat_map { |t| t[:functionDeclarations] }
      end

      def call(name, args)
        ::Thinking::Thinker.call_tool({ name: name, args: args },
          core: @core, llm_client: @llm_client, health: @health, character: @character)
      end

      private

      def usage_tracker(trigger_type)
        character = @character
        lambda do |model, usage|
          ApiUsageLog.record!(user: character.user, character: character, trigger_type: trigger_type, llm_model: model, usage: usage)
        rescue => e
          Rails.logger.warn("[ClaudeCli::ToolProvider] Usage tracking failed: #{e.message}")
        end
      end
    end

    class Chat
      def initialize(character, platform:, record_id: nil)
        @session =
          if record_id
            ::ChatSession.new(character, record: ::ChatSessionRecord.find(record_id), platform: platform)
          else
            ::ChatSession.find_or_create(character, character.user, platform: platform)
          end
      end

      def tools
        @session.tool_definitions.flat_map { |t| t[:functionDeclarations] }
      end

      def call(name, args)
        @session.call_tool(name, args)
      end
    end

    # 常駐の claude 用の会話のツール。1つの会話の記録に1本の claude を使い続けるので、経路（platform）が変わる。
    # ツール一覧は、すべての経路のツールの和集合（起動時に固定）。呼ばれたときに、route_path のファイル
    # （Runner が毎ターン書く）から、いまの経路を読んで、使えるツールかを確かめて実行する
    class RoutedChat
      def initialize(character, record_id:, route_path:)
        @character = character
        @record_id = record_id
        @route_path = route_path
        @catalog = ToolCatalog.merge(ConversationRoute::PLATFORMS.to_h { |platform| [ platform, definitions(platform) ] })
      end

      def tools
        @catalog[:tools]
      end

      def call(name, args)
        platform = current_route.platform
        return { error: "「#{name}」は、いまの経路（#{platform || "API"}）では使えません" } unless ToolCatalog.available?(@catalog[:platforms], name, platform)

        session(platform).call_tool(name, args)
      end

      private

      def current_route
        ConversationRoute.parse(File.exist?(@route_path) ? File.read(@route_path, encoding: "utf-8") : nil)
      end

      def session(platform)
        ::ChatSession.new(@character, record: ::ChatSessionRecord.find(@record_id), platform: platform)
      end

      def definitions(platform)
        session(platform).tool_definitions.flat_map { |t| t[:functionDeclarations] }
      end
    end
  end
end
