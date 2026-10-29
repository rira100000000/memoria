module ClaudeCli
  # MCP サーバ（bin/memoria_mcp）に渡すツールの出どころ。
  # 会話は ChatSession の、思考ループは Thinker のツールをそのまま使う（Gemini の場合と同じツールと実行処理）。
  # long_think_path を渡すと、長考の宣言（ClaudeCli::LongThink）のツールを足す
  module ToolProvider
    # @param record_id [Integer, nil] 会話の場面で、この会話の記録に結びつける（常駐の claude は、起動時の記録のまま長く動くため）。
    #   nil なら、そのときの有効な会話に結びつく
    def self.build(character:, scene:, platform: nil, trigger_type: nil, long_think_path: nil, record_id: nil)
      provider =
        case scene.to_sym
        when :thinking then Thinking.new(character, trigger_type: trigger_type || "thinking_loop")
        when :chat then Chat.new(character, platform: platform&.to_sym, record_id: record_id)
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
  end
end
