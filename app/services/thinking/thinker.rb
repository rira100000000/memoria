module Thinking
  # 思考の本体。AI自身に自由に行動させる
  # 「何がしたい？次はいつ起こしてほしい？」とだけ聞く
  class Thinker
    BASE_PROMPT = <<~PROMPT
      これはあなたの自由な時間です。
      以下はあなたの今の状況です。

      何かしたいことがあれば、利用可能なツールを使って行動できます。
      何もしたくなければ、それでも構いません。

      %{pet_section}

      ## スケジュール
      次にいつ起きたいか、add_scheduleツールで予定を入れてください。
      複数の予定を入れることもできます（例: 朝の挨拶と夜のリマインダー）。
      list_schedulesで今後の予定を確認、cancel_scheduleでキャンセルできます。
      特に理由がなければ長めの間隔で構いません。

      ## 終わったら
      以下のJSONで教えてください:
      ```json
      {
        "summary": "今回やったことの簡単なまとめ（1〜3行）",
        "share_message": "今すぐマスターに伝えたいこと（なければnull）"
      }
      ```
    PROMPT

    PET_SECTION_WITH_PET = <<~PET
      ## あなたの相棒
      あなたのそばに%{pet_name}（%{pet_appearance}）がいます。
      特徴: %{pet_traits}
      talk_to_petでいつでも話しかけられます。
      この子は長期の記憶を持てません。前に話したことは覚えていません。
      でもあなたのことが大好きで、いつもそばにいます。
    PET

    PET_SECTION_WITHOUT_PET = <<~PET
      ## 小さな相棒を迎え入れませんか？
      あなたの内面世界に、小さな相棒を迎え入れることができます。
      adopt_petツールで姿を選び、名前をつけてあげてください。
      この子はあなただけの唯一無二のパートナーになります。
    PET

    MAX_TOOL_ROUNDS = 5

    def self.run(snapshot:, character:, core:, health:, llm_client:)
      messages = []       # FL用の人間が読めるログ
      participants = [:self]
      tools = build_tools(character)
      reading_occurred = false
      last_reading_context = nil  # { progress_id:, finished: }

      prompt = build_prompt(character) + "\n\n" + snapshot

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

          # 直前にread_aozoraでチャンクを読んでいた場合、読書ノートを蓄積
          if last_reading_context
            save_reading_note(
              last_reading_context[:progress_id],
              chunk_text: last_reading_context[:chunk_text],
              llm_client: llm_client, character: character
            )
            last_reading_context = nil
          end
        end

        # Function Callがなければ完了
        break if result[:function_calls].empty?

        # gemini_messagesに応答を追加（raw_partsでthoughtSignatureを保持）
        gemini_messages << { role: "model", parts: result[:raw_parts] }

        # ツール実行
        has_non_reading_tool = false
        function_responses = result[:function_calls].map do |fc|
          tool_result = execute_tool(fc, core: core, llm_client: llm_client, health: health, character: character)
          participants << :pet if fc[:name] == "talk_to_pet"
          participants << :reading_companion if fc[:name] == "talk_to_reading_companion"
          log_tool_interaction(messages, fc, tool_result, character)

          # 読書チャンク処理
          if fc[:name] == "read_aozora" && tool_result.is_a?(Hash) && tool_result[:chunk].present?
            reading_occurred = true
            last_reading_context = {
              progress_id: tool_result[:reading_progress_id],
              chunk_text: tool_result[:chunk],
            }
            recalled = recall_memories_for(tool_result[:chunk], core: core, llm_client: llm_client)
            tool_result[:recalled_memories] = recalled if recalled.present?
          elsif fc[:name] != "read_aozora"
            has_non_reading_tool = true
          end

          # 読書伴走者との対話をreading_notesに記録
          if fc[:name] == "talk_to_reading_companion" && tool_result.is_a?(Hash) && tool_result[:response]
            progress = character.current_reading
            if progress
              progress.append_reading_log([
                { "type" => "dialogue", "speaker" => "hal", "text" => fc[:args]["message"] },
                { "type" => "dialogue", "speaker" => "companion", "text" => tool_result[:response] },
              ])
            end
          end

          { name: fc[:name], response: tool_result }
        end

        # read_aozora以外のツールが呼ばれた場合のみリセット（読書→感想のチャンスを維持）
        last_reading_context = nil if has_non_reading_tool && !reading_occurred

        # ツール結果をgemini_messagesに追加
        gemini_messages << {
          role: "user",
          parts: function_responses.map { |fr|
            { functionResponse: { name: fr[:name], response: fr[:response] } }
          },
        }
      end

      # ループ終了時にまだ蓄積されていない読書コンテキストがあれば読書ノートを保存
      if last_reading_context
        save_reading_note(
          last_reading_context[:progress_id],
          chunk_text: last_reading_context[:chunk_text],
          llm_client: llm_client, character: character
        )
      end

      ThinkingResult.parse(messages, participants: participants.uniq, reading_occurred: reading_occurred)
    end

    class << self
      private

      def build_prompt(character)
        if character.has_pet?
          pet_section = format(PET_SECTION_WITH_PET,
            pet_name: character.pet_name,
            pet_appearance: character.pet_appearance,
            pet_traits: character.pet_traits || "")
        else
          pet_section = PET_SECTION_WITHOUT_PET
        end
        format(BASE_PROMPT, pet_section: pet_section)
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
        fns += Thinking::ScheduleTools.definitions[:functionDeclarations]
        fns += Thinking::MemoryMaintenanceTools.definitions[:functionDeclarations]
        fns += Thinking::WebSearchTool.definition[:functionDeclarations]
        fns += Companion::TalkToPetTool.definition[:functionDeclarations]
        fns += Companion::AdoptPetTool.definition[:functionDeclarations] unless character.has_pet?
        if character.reading_enabled?
          fns += Reading::AozoraTool.definition[:functionDeclarations]
          fns += Reading::TalkToCompanionTool.definition[:functionDeclarations] if character.reading_companion
        end

        [{ functionDeclarations: fns }]
      end

      def execute_tool(fc, core:, llm_client:, health:, character:)
        result = case fc[:name]
        when "talk_to_pet"
          Companion::TalkToPetTool.execute(
            fc[:args]["message"],
            llm_client: llm_client,
            health: health,
            character: character
          )
        when "adopt_pet"
          Companion::AdoptPetTool.execute(
            character: character,
            name: fc[:args]["name"],
            appearance: fc[:args]["appearance"]
          )
        when "list_schedules", "add_schedule", "cancel_schedule"
          Thinking::ScheduleTools.execute(fc[:name], fc[:args], character: character, autonomous: true)
        when "list_yesterdays_memories", "merge_memories", "archive_memory"
          Thinking::MemoryMaintenanceTools.execute(fc[:name], fc[:args], core: core, character: character, llm_client: llm_client)
        when "web_search"
          Thinking::WebSearchTool.execute(fc[:args]["query"], llm_client: llm_client)
        when "read_aozora"
          Reading::AozoraTool.execute(
            action: fc[:args]["action"],
            genre: fc[:args]["genre"],
            query: fc[:args]["query"],
            work_id: fc[:args]["work_id"],
            character: character,
            llm_client: llm_client
          )
        when "talk_to_reading_companion"
          Reading::TalkToCompanionTool.execute(
            fc[:args]["message"],
            llm_client: llm_client,
            character: character
          )
        when "read_memory"
          execute_read_memory(fc[:args]["query"], core: core, llm_client: llm_client)
        else
          { error: "Unknown tool: #{fc[:name]}" }
        end

        # Gemini APIのfunctionResponse.responseはStructが必須（文字列不可）
        result.is_a?(Hash) ? result : { response: result.to_s }
      end

      # ツール呼び出しをFL用メッセージとして記録
      def log_tool_interaction(messages, fc, tool_result, character)
        case fc[:name]
        when "talk_to_pet"
          pet_name = character.pet_name || "ペット"
          messages << { role: "model", content: fc[:args]["message"], participant: "#{character.name} → #{pet_name}" }
          pet_response = tool_result.is_a?(Hash) ? tool_result[:response].to_s : tool_result.to_s
          messages << { role: "tool", content: pet_response, participant: pet_name }
        when "talk_to_reading_companion"
          companion_name = Reading::ReadingCompanion::NAME
          messages << { role: "model", content: fc[:args]["message"], participant: "#{character.name} → #{companion_name}" }
          companion_response = tool_result.is_a?(Hash) ? tool_result[:response].to_s : tool_result.to_s
          messages << { role: "tool", content: companion_response, participant: companion_name }
        when "adopt_pet"
          msg = tool_result.is_a?(Hash) ? tool_result[:message].to_s : tool_result.to_s
          messages << { role: "tool", content: "[相棒を迎え入れた] #{msg}", participant: "system" }
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
        when "read_aozora"
          if tool_result.is_a?(Hash) && tool_result[:title]
            title = tool_result[:title]
            author = tool_result[:author]
            progress = tool_result[:progress]
            finished = tool_result[:finished] ? "（読了）" : ""
            preview = tool_result[:chunk].to_s.slice(0, 100)
            messages << { role: "tool", content: "[読書: #{author}「#{title}」#{progress}#{finished}] #{preview}…", participant: "system" }
          elsif tool_result.is_a?(Hash) && tool_result[:results]
            items = tool_result[:results].map { |r| "#{r[:author]}「#{r[:title]}」(ID:#{r[:work_id]})" }.join(", ")
            messages << { role: "tool", content: "[読書検索] #{items.presence || "該当なし"}", participant: "system" }
          else
            error = tool_result.is_a?(Hash) ? (tool_result[:error] || tool_result[:message]) : tool_result.to_s
            messages << { role: "tool", content: "[読書] #{error}", participant: "system" }
          end
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

      def save_reading_note(progress_id, chunk_text: nil, llm_client: nil, character: nil)
        progress = ReadingProgress.find_by(id: progress_id)
        return unless progress && chunk_text.present?

        entries = []

        # 最初のチャンク: 伴走者とのアイスブレイク
        if progress.parsed_notes.empty? && llm_client && character&.reading_companion
          companion = Reading::ReadingCompanion.new(llm_client: llm_client, for_character: character)
          ice_break = companion.ice_break(
            work_title: progress.title,
            work_author: progress.author,
            character_name: character.name
          )
          entries << { "type" => "dialogue", "speaker" => "companion", "text" => ice_break } if ice_break.present?
        end

        # 原文チャンクを記録
        entries << {
          "type" => "narration",
          "text" => chunk_text,
          "chunk_range" => progress.current_position.to_s,
        }

        progress.append_reading_log(entries)
      rescue => e
        Rails.logger.warn("[Thinker] Failed to save reading note: #{e.message}")
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
