module Reading
  # 読了時に蓄積された読書ノートから統合SNを1つ生成する
  class ReadingSummaryService
    def initialize(character, llm_client:)
      @character = character
      @llm_client = llm_client
      @vault = MemoriaCore::VaultManager.new(character.vault_path)
      @vault.ensure_structure!
      @embedding_store = MemoriaCore::EmbeddingStore.new(@vault, @llm_client)
      @embedding_store.initialize!
    end

    def generate_for(reading_progress)
      notes_text = reading_progress.combined_notes_text
      return nil if notes_text.blank?

      prompt = if reading_progress.status == "abandoned"
        build_abandoned_prompt(reading_progress, notes_text)
      else
        build_integrated_prompt(reading_progress, notes_text)
      end

      result = @llm_client.generate(prompt)
      parsed = parse_json_response(result[:text])
      return nil unless parsed

      save_summary_note(parsed, reading_progress)
    end

    private

    def build_integrated_prompt(progress, notes_text)
      <<~PROMPT
        あなたは、以下のキャラクター設定を持つ #{@character.name} です。
        このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

        あなたのキャラクター設定:
        ---
        #{@character.system_prompt}
        ---

        あなたは#{progress.author}「#{progress.title}」を読了しました（全#{progress.total_length}字）。
        以下は読書中の原文・あなたの感想・読書伴走者との対話の記録です:

        ---
        #{notes_text}
        ---

        これらの断片的な感想を統合し、作品全体の読書体験として振り返ってください。
        チャンクごとの感想をそのまま列挙するのではなく、
        全体を通した印象・発見・感情の変化を一つのまとまった振り返りにしてください。

        以下の観点を含めてください:
        - 作品全体の印象と読後感
        - 最も心に残った場面や表現とその理由
        - 登場人物への共感や反感
        - 読書を通じた自分の感情や考えの変化
        - マスターに薦めたいかどうか、その理由

        tagsには必ず "reading" と、著者名・作品名を含めてください。

        ```json
        {
          "conversationTitle": "読書感想のタイトル（10語以内、作品名を含む）",
          "tags": ["reading", "著者名", "作品名"],
          "mood": "読後の気分を表す言葉",
          "keyTakeaways": ["この作品から得た重要な気づきを1～3点"],
          "actionItems": ["#{@character.name}: 次に読みたい作品やジャンル", "#{@character.name}: マスターに伝えたいこと"],
          "reflectionBody": "統合された読書感想（マークダウン形式）",
          "semanticDefinitions": [{"tag": "概念名", "definition": "作品を通じて理解した概念の定義"}]
        }
        ```
        JSONオブジェクトのみを返し、他のテキストは含めないでください。
      PROMPT
    end

    def build_abandoned_prompt(progress, notes_text)
      <<~PROMPT
        あなたは、以下のキャラクター設定を持つ #{@character.name} です。
        このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

        あなたのキャラクター設定:
        ---
        #{@character.system_prompt}
        ---

        あなたは#{progress.author}「#{progress.title}」を途中まで読みましたが、読むのをやめました（#{progress.current_position}/#{progress.total_length}字）。
        以下は読書中に書き留めた感想の記録です:

        ---
        #{notes_text}
        ---

        途中までの読書体験を振り返ってください。
        なぜ最後まで読まなかったのか、読んだ部分からどんな印象を受けたかをまとめてください。

        tagsには必ず "reading" と、著者名・作品名を含めてください。

        ```json
        {
          "conversationTitle": "読書感想のタイトル（10語以内、作品名を含む）",
          "tags": ["reading", "著者名", "作品名"],
          "mood": "読後の気分を表す言葉",
          "keyTakeaways": ["途中まで読んで得た気づきを1～3点"],
          "actionItems": ["#{@character.name}: 今後の読書計画"],
          "reflectionBody": "途中までの読書感想（マークダウン形式）",
          "semanticDefinitions": [{"tag": "概念名", "definition": "作品を通じて理解した概念の定義"}]
        }
        ```
        JSONオブジェクトのみを返し、他のテキストは含めないでください。
      PROMPT
    end

    def parse_json_response(text)
      json_match = text.match(/```json\s*(.*?)\s*```/m)
      json_str = json_match ? json_match[1] : text
      JSON.parse(json_str)
    rescue JSON::ParserError
      nil
    end

    def save_summary_note(parsed, progress)
      timestamp = Time.now.strftime("%Y%m%d%H%M")
      sn_base = MemoriaCore::SnStore.build_base_name(timestamp, parsed["conversationTitle"])
      tags = [@character.name] + (parsed["tags"] || [])
      tags = tags.uniq

      semantic_defs = (parsed["semanticDefinitions"] || [])
        .select { |d| d["tag"] && d["definition"] && !d["definition"].strip.empty? }

      sn_fm = MemoriaCore::SnStore.build_frontmatter(
        title: parsed["conversationTitle"],
        llm_role_name: @character.name,
        tags: tags,
        full_log_ref: "",
        mood: parsed["mood"],
        key_takeaways: parsed["keyTakeaways"],
        action_items: parsed["actionItems"],
        semantic_definitions: semantic_defs
      )

      body_content = parsed["reflectionBody"].to_s.gsub('\n', "\n")
      sn_body = "# #{parsed['conversationTitle']} (by #{@character.name})\n\n#{body_content}\n"

      sn_store = MemoriaCore::SnStore.new(@vault)
      sn_store.save("#{sn_base}.md", sn_fm, sn_body)

      sn_relative_path = sn_store.path_for("#{sn_base}.md")
      sn_content = MemoriaCore::Frontmatter.build(sn_fm, sn_body)
      @embedding_store.embed_and_store(
        sn_relative_path, sn_content, "SN",
        { title: parsed["conversationTitle"], tags: tags }
      )

      { file_path: sn_relative_path, base_name: sn_base, tags: tags }
    end
  end
end
