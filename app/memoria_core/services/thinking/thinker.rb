module Thinking
  # 思考の本体。AI自身に自由に行動させる
  # 「何がしたい？次はいつ起こしてほしい？」とだけ聞く
  class Thinker
    BASE_PROMPT = <<~PROMPT
      あなたは今、会話の外で起きています。
      以下はあなたの今の状況です。

      やることや、やりたいことがあれば、利用可能なツールを使って行動できます。
      何もしなくても構いません。

      ## スケジュール
      次にいつ起きたいか、add_scheduleツールで予定を入れられます。
      複数の予定を入れることもできます（例: 朝の挨拶と夜のリマインダー）。
      list_schedulesで今後の予定を確認、cancel_scheduleでキャンセルできます。
      毎日・毎週など繰り返したい予定は repeat にcron式で指定できます。
      %{approval_note}

      ## 終わったら
      下のJSONを書くと、この回は終わります。やると決めたことは、書く前にこの回の中で済ませてください。
      この回で終わらないことは、続きの予定を入れるか、任せられるツールがあれば任せてください。
      以下のJSONで教えてください:
      ```json
      {
        "summary": "今回やったことの簡単なまとめ（1〜3行）",
        "share_message": "今すぐユーザーに伝えたいこと（なければnull）"
      }
      ```
    PROMPT

    MAX_TOOL_ROUNDS = 5

    # @param usage_context [Hash, nil] ツールの使用記録に添える場面の情報（ClaudeCli::Runner#run の usage_context）
    def self.run(snapshot:, character:, core:, health:, llm_client:, usage_context: nil)
      prompt = build_prompt(character) + "\n\n" + snapshot
      plugin_segments = MemoriaServer::Plugin.prompt_segments(character, scene: :thinking)
      prompt += "\n\n" + plugin_segments if plugin_segments.present?

      # システムインストラクション。会話と同じく、今の状況（起きた理由・直近の会話・前回の活動）から
      # 記憶を想起して渡す。記憶がないと、起きるたびに別人のように振る舞う
      prompt_builder = PromptBuilder.new(character)
      system_instruction = prompt_builder.build(context: {
        retrieved_context: recall_memories_for(snapshot, core: core, llm_client: llm_client) || "",
        narrative_summary: "",
        behavior_principles: load_behavior_principles(core),
        prospective_memory: ProspectiveMemory.scan(core.vault),
      }, channel: "autonomous thinking")

      # claude -p が使えないときは ClaudeCli::Error が上がる（Gemini で代わりに動くことはしない）
      if ClaudeCli.enabled?
        return run_with_claude(prompt: prompt, system_instruction: system_instruction,
          character: character, llm_client: llm_client, usage_context: usage_context)
      end

      run_with_gemini(prompt: prompt, system_instruction: system_instruction,
        character: character, core: core, health: health, llm_client: llm_client)
    end

    # claude -p で考える。ツールは MCP サーバ（bin/memoria_mcp）が実行し、その記録を受け取って
    # Gemini の場合と同じ形のログにする
    def self.run_with_claude(prompt:, system_instruction:, character:, llm_client:, usage_context: nil)
      run = ClaudeCli::Runner.new.run(
        system_prompt: system_instruction,
        prompt: prompt,
        character: character,
        scene: :thinking,
        model: ClaudeCli.model,
        trigger_type: "thinking_loop",
        usage_context: usage_context
      )

      messages = []
      participants = [:self]

      run.tool_events.each do |event|
        fc = { name: event[:name], args: event[:args] }
        participants << event[:result][:participant] if event[:result].is_a?(Hash) && event[:result][:participant].present?
        log_tool_interaction(messages, fc, event[:result], character)
      end

      messages << { role: "model", content: run.text, participant: character.name } if run.text.present?

      ThinkingResult.parse(messages, participants: participants.uniq)
    end

    def self.run_with_gemini(prompt:, system_instruction:, character:, core:, health:, llm_client:)
      messages = []       # FL用の人間が読めるログ
      participants = [:self]
      tools = tool_definitions(character)

      # Gemini API用メッセージ
      gemini_messages = [{ role: "user", parts: [{ text: prompt }] }]

      MAX_TOOL_ROUNDS.times do
        result = llm_client.chat(
          gemini_messages,
          system_instruction: system_instruction,
          tools: tools
        )

        # テキスト応答があれば記録
        messages << { role: "model", content: result[:text], participant: character.name } if result[:text].present?

        # Function Callがなければ完了
        break if result[:function_calls].empty?

        # gemini_messagesに応答を追加（raw_partsでthoughtSignatureを保持）
        gemini_messages << { role: "model", parts: result[:raw_parts] }

        # ツール実行
        function_responses = result[:function_calls].map do |fc|
          tool_result = call_tool(fc, core: core, llm_client: llm_client, health: health, character: character)
          participants << tool_result[:participant] if tool_result.is_a?(Hash) && tool_result[:participant].present?
          log_tool_interaction(messages, fc, tool_result, character)

          { name: fc[:name], response: tool_result.except(:log, :participant) }
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
      # 思考ループで使えるツールの定義（Gemini の functionDeclarations 形式）。
      # claude -p のときは MCP サーバがこれを JSON Schema に直して渡す
      def tool_definitions(character)
        build_tools(character)
      end

      # ツールを実行する
      def call_tool(fc, core:, llm_client:, health:, character:)
        execute_tool(fc, core: core, llm_client: llm_client, health: health, character: character)
      end

      private

      def build_prompt(character)
        approval_note = if MemoriaServer::Plugin.schedule_policy(character)[:self_recurring_needs_approval]
          "あなたが自分で入れた繰り返しの予定は、ユーザーが承認するまで動きません。"
        else
          ""
        end
        format(BASE_PROMPT, approval_note: approval_note)
      end

      def build_tools(character)
        memory_fn = {
          name: "read_memory",
          description: "記憶を検索して関連する情報を取得する",
          parameters: {
            type: "OBJECT",
            properties: {
              query: { type: "STRING", description: "検索したい内容" },
            },
            required: ["query"],
          },
        }

        fns = [memory_fn]
        fns += Thinking::MemoryMaintenanceTools.definitions[:functionDeclarations]
        # claude -p のときは Claude Code の WebSearch を使う（ClaudeCli::Runner）
        fns += Thinking::WebSearchTool.definition[:functionDeclarations] unless ClaudeCli.enabled?

        # 予定の管理などはプラグインとして足される
        fns += MemoriaServer::Plugin.gemini_declarations(character, scene: :thinking)

        [{ functionDeclarations: fns }]
      end

      def execute_tool(fc, core:, llm_client:, health:, character:)
        result = case fc[:name]
        when "list_yesterdays_memories", "merge_memories", "archive_memory"
          Thinking::MemoryMaintenanceTools.execute(fc[:name], fc[:args], core: core, character: character, llm_client: llm_client)
        when "web_search"
          Thinking::WebSearchTool.execute(fc[:args]["query"], llm_client: llm_client)
        when "read_memory"
          execute_read_memory(fc[:args]["query"], core: core, llm_client: llm_client)
        else
          MemoriaServer::Plugin.execute(fc[:name], fc[:args], character: character, scene: :thinking) ||
            { error: "Unknown tool: #{fc[:name]}" }
        end

        # Gemini APIのfunctionResponse.responseはStructが必須（文字列不可）
        result.is_a?(Hash) ? result : { response: result.to_s }
      end

      # ツール呼び出しをFL用メッセージとして記録
      def log_tool_interaction(messages, fc, tool_result, character)
        # プラグインのツールが会話ログに残す文を返したときは、それをそのまま残す（会話のときと同じ）
        if tool_result.is_a?(Hash) && tool_result[:log].present?
          Array(tool_result[:log]).each { |entry| messages << { role: "tool", content: entry.to_s, raw: true } }
          return
        end

        case fc[:name]
        when "add_schedule"
          time = tool_result.is_a?(Hash) ? tool_result[:scheduled_at] : ""
          purpose = tool_result.is_a?(Hash) ? tool_result[:purpose] : ""
          messages << { role: "tool", content: "[スケジュール追加] #{time} — #{purpose}", participant: "system" }
        when "cancel_schedule"
          purpose = tool_result.is_a?(Hash) ? tool_result[:purpose] : ""
          messages << { role: "tool", content: "[スケジュールキャンセル] #{purpose}", participant: "system" }
        when "list_schedules"
          schedules = tool_result.is_a?(Hash) ? tool_result[:schedules] : ""
          messages << { role: "tool", content: "[スケジュール確認]\n#{schedules}", participant: "system" }
        when "list_yesterdays_memories"
          count = tool_result.is_a?(Hash) ? tool_result[:count] : 0
          messages << { role: "tool", content: "[昨日の記憶一覧] #{count || 0}件", participant: "system" }
        when "merge_memories"
          merged = tool_result.is_a?(Hash) ? tool_result[:merged_as] : ""
          messages << { role: "tool", content: "[記憶統合] → #{merged}", participant: "system" }
        when "archive_memory"
          archived = tool_result.is_a?(Hash) ? tool_result[:archived] : ""
          messages << { role: "tool", content: "[記憶アーカイブ] #{archived}", participant: "system" }
        when "web_search"
          answer = tool_result.is_a?(Hash) ? tool_result[:answer].to_s.slice(0, 300) : tool_result.to_s.slice(0, 300)
          messages << { role: "tool", content: "[Web検索: #{fc[:args]["query"]}] #{answer}", participant: "system" }
        when "read_memory"
          text = tool_result.is_a?(Hash) ? tool_result[:results].to_s : tool_result.to_s
          messages << { role: "tool", content: "[記憶検索] #{text.length}文字の記憶を参照", participant: "system" }
        else
          messages << { role: "tool", content: "[#{fc[:name]}] #{tool_result.to_s.slice(0, 200)}", participant: fc[:name] }
        end
      end

      def execute_read_memory(query, core:, llm_client:)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        retriever = MemoriaCore::ContextRetriever.new(core.vault, embedding_store)
        result = retriever.retrieve(query)
        { results: result[:llm_context_prompt] }
      end

      def recall_memories_for(text, core:, llm_client:)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        retriever = MemoriaCore::ContextRetriever.new(core.vault, embedding_store)
        result = retriever.retrieve(text)
        result[:llm_context_prompt]
      rescue => e
        Rails.logger.warn("[Thinker] Memory recall failed: #{e.message}")
        nil
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
