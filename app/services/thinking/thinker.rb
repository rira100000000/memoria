module Thinking
  # 思考の本体。AI自身に自由に行動させる
  # 「何がしたい？次はいつ起こしてほしい？」とだけ聞く
  class Thinker
    SYSTEM_PROMPT = <<~PROMPT
      あなたは今目を覚ましました。
      以下はあなたの今の状況です。
      自由に過ごしてください。

      何かしたいことがあれば、利用可能なツールを使って行動できます。
      何もしたくなければ、それでも構いません。

      行動が終わったら、以下のJSONで教えてください:
      ```json
      {
        "summary": "今回やったことの簡単なまとめ（1〜3行）",
        "share_message": "マスターに共有したいこと（なければnull）",
        "next_wakeup": "次にいつ目を覚ましたいか（例: 3時間後、明日の朝、14時）"
      }
      ```
      特に理由がなければ長めに眠って構いません。
    PROMPT

    MAX_TURNS = 3

    def self.run(snapshot:, character:, core:, health:, llm_client:)
      messages = []
      participants = [:self]
      tools = build_tools

      prompt = SYSTEM_PROMPT + "\n\n" + snapshot

      # システムインストラクション（キャラクター設定 + memoria指示）
      prompt_builder = PromptBuilder.new(character)
      system_instruction = prompt_builder.build(context: {
        retrieved_context: "",
        narrative_summary: "",
        behavior_principles: load_behavior_principles(core),
        prospective_memory: "",
      })

      # 思考ループ（最大MAX_TURNSターン）
      gemini_messages = [{ role: "user", parts: [{ text: prompt }] }]

      MAX_TURNS.times do |turn|
        model_tier = turn == 0 ? :light : :main
        result = llm_client.generate(
          prompt,
          tier: model_tier,
          system_instruction: system_instruction,
          tools: tools
        ) if turn == 0

        if turn > 0
          result = llm_client.chat(
            gemini_messages,
            system_instruction: system_instruction,
            tools: tools
          )
        end

        # メッセージ記録
        messages << { role: "model", content: result[:text], participant: character.name }

        # Function Callがなければ完了
        break if result[:function_calls].empty?

        # Function Call処理
        model_parts = []
        model_parts << { text: result[:text] } if result[:text].present?
        result[:function_calls].each do |fc|
          model_parts << { functionCall: { name: fc[:name], args: fc[:args] } }
        end
        gemini_messages << { role: "model", parts: model_parts }

        function_responses = result[:function_calls].map do |fc|
          tool_result = execute_tool(fc, core: core, llm_client: llm_client, health: health)
          participants << :pet if fc[:name] == "talk_to_pet"
          messages << { role: "tool", content: "#{fc[:name]}: #{tool_result.to_json}", participant: fc[:name] }
          { name: fc[:name], response: tool_result }
        end

        # ツール結果をgemini_messagesに追加
        gemini_messages << {
          role: "user",
          parts: function_responses.map { |fr|
            { functionResponse: { name: fr[:name], response: fr[:response] } }
          },
        }
      end

      ThinkingResult.parse(messages, participants: participants.uniq)
    end

    class << self
      private

      def build_tools
        [
          Companion::TalkToPetTool.definition,
          read_memory_tool_definition,
        ]
      end

      def read_memory_tool_definition
        {
          functionDeclarations: [{
            name: "read_memory",
            description: "記憶を検索して関連する情報を取得する",
            parameters: {
              type: "OBJECT",
              properties: {
                query: { type: "STRING", description: "検索したい内容" },
              },
              required: ["query"],
            },
          }],
        }
      end

      def execute_tool(fc, core:, llm_client:, health:)
        case fc[:name]
        when "talk_to_pet"
          Companion::TalkToPetTool.execute(
            fc[:args]["message"],
            llm_client: llm_client,
            health: health
          )
        when "read_memory"
          execute_read_memory(fc[:args]["query"], core: core, llm_client: llm_client)
        else
          { error: "Unknown tool: #{fc[:name]}" }
        end
      end

      def execute_read_memory(query, core:, llm_client:)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        retriever = MemoriaCore::ContextRetriever.new(core.vault, embedding_store)
        result = retriever.retrieve(query)
        { results: result[:llm_context_prompt] }
      end

      def load_behavior_principles(core)
        path = core.vault.path_for("BehaviorPrinciples/principles.md")
        return "まだ原則は定められていない。" unless File.exist?(path)
        content = File.read(path, encoding: "utf-8")
        _, body = MemoriaCore::Frontmatter.parse(content)
        body.strip.empty? ? "まだ原則は定められていない。" : body
      end
    end
  end
end
