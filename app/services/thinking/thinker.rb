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

    MAX_TOOL_ROUNDS = 5

    def self.run(snapshot:, character:, core:, health:, llm_client:)
      messages = []       # FL用の人間が読めるログ
      participants = [:self]
      tools = build_tools

      prompt = SYSTEM_PROMPT + "\n\n" + snapshot

      # システムインストラクション
      prompt_builder = PromptBuilder.new(character)
      system_instruction = prompt_builder.build(context: {
        retrieved_context: "",
        narrative_summary: "",
        behavior_principles: load_behavior_principles(core),
        prospective_memory: "",
      }, channel: "autonomous thinking")

      # Gemini API用メッセージ
      gemini_messages = [{ role: "user", parts: [{ text: prompt }] }]

      MAX_TOOL_ROUNDS.times do
        result = llm_client.chat(
          gemini_messages,
          system_instruction: system_instruction,
          tools: tools
        )

        # テキスト応答があれば記録
        if result[:text].present?
          messages << { role: "model", content: result[:text], participant: character.name }
        end

        # Function Callがなければ完了
        break if result[:function_calls].empty?

        # gemini_messagesに応答を追加（raw_partsでthoughtSignatureを保持）
        gemini_messages << { role: "model", parts: result[:raw_parts] }

        # ツール実行
        function_responses = result[:function_calls].map do |fc|
          tool_result = execute_tool(fc, core: core, llm_client: llm_client, health: health)
          participants << :pet if fc[:name] == "talk_to_pet"
          messages << {
            role: "tool",
            content: "[#{fc[:name]}] #{summarize_tool_result(fc[:name], tool_result)}",
            participant: fc[:name],
          }
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
        pet_fns = Companion::TalkToPetTool.definition[:functionDeclarations]
        [{
          functionDeclarations: pet_fns + [{
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
        }]
      end

      def execute_tool(fc, core:, llm_client:, health:)
        result = case fc[:name]
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

        # Gemini APIのfunctionResponse.responseはStructが必須（文字列不可）
        result.is_a?(Hash) ? result : { response: result.to_s }
      end

      def execute_read_memory(query, core:, llm_client:)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        retriever = MemoriaCore::ContextRetriever.new(core.vault, embedding_store)
        result = retriever.retrieve(query)
        { results: result[:llm_context_prompt] }
      end

      # ツール結果をFL用に要約（read_memoryの巨大なレスポンスを短縮）
      def summarize_tool_result(name, result)
        case name
        when "read_memory"
          text = result[:results].to_s
          "#{text.length}文字の記憶を検索"
        when "talk_to_pet"
          result.to_s.slice(0, 200)
        else
          result.to_s.slice(0, 200)
        end
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
