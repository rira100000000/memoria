# 会話セッションの管理
# インメモリでメッセージ履歴を保持し、記憶検索→プロンプト構築→LLM呼び出し→ログ記録を統合
class ChatSession
  # messages: [{ role: "user"/"model", content: "..." }]
  attr_reader :messages, :character, :chat_logger

  def initialize(character, llm_client: nil)
    @character = character
    @llm_client = llm_client || LlmClient.new
    @messages = []
    @vault = MemoriaCore::VaultManager.new(character.vault_path)
    @vault.ensure_structure!
    @embedding_store = MemoriaCore::EmbeddingStore.new(@vault, @llm_client)
    @embedding_store.initialize!
    @context_retriever = MemoriaCore::ContextRetriever.new(@vault, @embedding_store)
    @chat_logger = MemoriaCore::ChatLogger.new(@vault, llm_role_name)
    @prompt_builder = PromptBuilder.new(character)
    @narrative_summary = ""
    @first_message = true
  end

  # ユーザーメッセージを受けてAI応答を生成
  def send_message(user_message)
    # ログファイルが未作成なら作成
    @chat_logger.setup! unless @chat_logger.current_log_path

    # ユーザーメッセージを記録
    @messages << { role: "user", content: user_message }
    @chat_logger.log_user_message(user_message)

    # コンテキスト取得（記憶検索）
    context = build_context(user_message)

    # システムインストラクション構築
    system_instruction = @prompt_builder.build(context: context)

    # Gemini API 用メッセージ構築
    gemini_messages = @messages.map do |m|
      { role: m[:role] == "user" ? "user" : "model", parts: [{ text: m[:content] }] }
    end

    # LLM呼び出し（Function Calling対応のツール定義）
    tools = build_tool_definitions
    result = @llm_client.chat(gemini_messages, system_instruction: system_instruction, tools: tools)

    # Function Call がある場合はループ処理
    while result[:function_calls]&.any?
      # 直前のmodel応答をメッセージ履歴に追加
      model_parts = []
      model_parts << { text: result[:text] } if result[:text] && !result[:text].empty?
      result[:function_calls].each do |fc|
        model_parts << { functionCall: { name: fc[:name], args: fc[:args] } }
      end
      gemini_messages << { role: "model", parts: model_parts }

      # ツール実行
      function_responses = result[:function_calls].map do |fc|
        tool_result = execute_tool(fc[:name], fc[:args])
        { name: fc[:name], response: tool_result }
      end

      result = @llm_client.send_function_response(
        gemini_messages, function_responses,
        system_instruction: system_instruction, tools: tools
      )
    end

    ai_response = result[:text]

    # AI応答を記録
    @messages << { role: "model", content: ai_response }
    @chat_logger.log_ai_message(ai_response)
    @first_message = false

    {
      response: ai_response,
      usage: result[:usage],
    }
  end

  # チャットリセット（振り返り生成 + セッションクリア）
  def reset!
    reflection_result = nil

    if @messages.length > 1 && @chat_logger.current_log_path
      reflection_result = generate_reflection
    end

    @chat_logger.reset!
    @messages = []
    @narrative_summary = ""
    @first_message = true

    reflection_result
  end

  private

  def llm_role_name
    @character.name
  end

  def build_context(user_message)
    # 記憶検索
    retrieved = @context_retriever.retrieve(user_message)

    # 前向き記憶（直近SNのaction_items）
    prospective = scan_action_items

    {
      retrieved_context: retrieved[:llm_context_prompt],
      narrative_summary: @narrative_summary,
      behavior_principles: load_behavior_principles,
      prospective_memory: prospective,
    }
  end

  def scan_action_items
    sn_store = MemoriaCore::SnStore.new(@vault)
    files = sn_store.list.sort.reverse.first(5)
    entries = []

    files.each do |file_path|
      content = @vault.read(file_path)
      next unless content
      fm, = MemoriaCore::Frontmatter.parse(content)
      next unless fm
      items = Array(fm["action_items"]).select { |i| i && !i.strip.empty? }
      next if items.empty?

      title = fm["title"] || File.basename(file_path, ".md")
      date_label = fm["date"] ? " (#{fm['date']})" : ""
      entries << "【#{title}#{date_label}】\n#{items.map { |i| "- #{i}" }.join("\n")}"
    end

    entries.join("\n")
  end

  def load_behavior_principles
    path = @vault.path_for("BehaviorPrinciples/principles.md")
    return "まだ原則は定められていない。" unless File.exist?(path)
    content = File.read(path, encoding: "utf-8")
    _, body = MemoriaCore::Frontmatter.parse(content)
    body.strip.empty? ? "まだ原則は定められていない。" : body
  end

  # --- 振り返り生成（ReflectionEngine相当） ---

  def generate_reflection
    formatted = @messages.map { |m|
      speaker = m[:role] == "user" ? "User" : llm_role_name
      "#{speaker}: #{m[:content]}"
    }.join("\n\n")

    prompt = build_reflection_prompt(formatted)
    result = @llm_client.generate(prompt)

    parsed = parse_reflection_response(result[:text])
    return nil unless parsed

    # SN 保存
    timestamp = MemoriaCore::FlStore.extract_timestamp(@chat_logger.log_file_name || "")
    sn_base = MemoriaCore::SnStore.build_base_name(timestamp, parsed["conversationTitle"])
    tags = [llm_role_name] + extract_tags(parsed["reflectionBody"]) + (parsed["tags"] || [])
    tags = tags.uniq

    semantic_defs = (parsed["semanticDefinitions"] || []).select { |d| d["tag"] && d["definition"] && !d["definition"].strip.empty? }

    sn_fm = MemoriaCore::SnStore.build_frontmatter(
      title: parsed["conversationTitle"],
      llm_role_name: llm_role_name,
      tags: tags,
      full_log_ref: @chat_logger.log_file_name || "",
      mood: parsed["mood"],
      key_takeaways: parsed["keyTakeaways"],
      action_items: parsed["actionItems"],
      semantic_definitions: semantic_defs
    )

    body_content = parsed["reflectionBody"].gsub('\n', "\n")
    sn_body = "# #{parsed['conversationTitle']} (by #{llm_role_name})\n\n#{body_content}\n"

    sn_store = MemoriaCore::SnStore.new(@vault)
    sn_store.save("#{sn_base}.md", sn_fm, sn_body)

    # FullLogのfrontmatter更新
    @chat_logger.update_frontmatter(
      "title" => parsed["conversationTitle"],
      "summary_note" => "[[#{sn_base}.md]]"
    )

    # Embedding更新
    sn_content = MemoriaCore::Frontmatter.build(sn_fm, sn_body)
    @embedding_store.embed_and_store(
      sn_store.path_for("#{sn_base}.md"), sn_content, "SN",
      { title: parsed["conversationTitle"], tags: tags }
    )

    # タグプロファイリング
    tag_profiler = MemoriaCore::TagProfiler.new(@vault, @llm_client, {
      llm_role_name: llm_role_name,
      system_prompt: @character.system_prompt,
    })
    tag_profiler.process_summary_note(sn_store.path_for("#{sn_base}.md"))

    # 更新されたTPNのEmbedding更新
    tags.each do |tag|
      tpn_store = MemoriaCore::TpnStore.new(@vault)
      tpn_content = tpn_store.read_raw(tag)
      next unless tpn_content
      @embedding_store.embed_and_store(
        tpn_store.path_for(tag), tpn_content, "TPN",
        { title: tag, tags: [tag] }
      )
    end

    { file_path: sn_store.path_for("#{sn_base}.md"), base_name: sn_base, tags: tags }
  rescue => e
    Rails.logger.error("[ChatSession] Reflection failed: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}") if defined?(Rails)
    nil
  end

  def build_reflection_prompt(formatted_history)
    <<~PROMPT
      あなたは、以下のキャラクター設定を持つ #{llm_role_name} です。
      このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

      あなたのキャラクター設定:
      ---
      #{@character.system_prompt}
      ---

      たった今、ユーザーとの以下の会話を終えました。この会話全体を振り返り、以下の指示に従って情報を整理してください。

      会話履歴:
      ---
      #{formatted_history}
      ---

      以下のJSONオブジェクトの各フィールドを記述してください。
      ```json
      {
        "conversationTitle": "この会話にふさわしい簡潔なタイトル（10語以内）",
        "tags": [],
        "mood": "会話全体の雰囲気を表す言葉",
        "keyTakeaways": ["重要な結論や決定事項を1～3点"],
        "actionItems": ["User: アクション", "#{llm_role_name}: アクション"],
        "reflectionBody": "## その日の会話のテーマ\\n\\n## 特に印象に残った発言\\n\\n## 新しい発見や気づき\\n\\n## 感情の変化\\n\\n## 今後の課題や目標\\n\\n## 自由形式での感想\\n",
        "semanticDefinitions": [{"tag": "概念名", "definition": "ユーザーが説明した定義"}]
      }
      ```
      JSONオブジェクトのみを返し、他のテキストは含めないでください。
    PROMPT
  end

  def parse_reflection_response(text)
    json_match = text.match(/```json\s*(.*?)\s*```/m)
    json_str = json_match ? json_match[1] : text
    JSON.parse(json_str)
  rescue JSON::ParserError
    nil
  end

  def extract_tags(text)
    return [] unless text
    # シンプルなタグ抽出（LLM呼び出しを省略、Phase2以降で改善）
    []
  end

  # --- Function Calling ---

  def build_tool_definitions
    [
      {
        functionDeclarations: [
          {
            name: "semantic_search",
            description: "記憶のセマンティック検索を実行し、関連する記憶を返す",
            parameters: {
              type: "OBJECT",
              properties: {
                query: { type: "STRING", description: "検索クエリ" },
              },
              required: ["query"],
            },
          },
          {
            name: "conversation_reflection",
            description: "現在の会話を振り返り、サマリーノートを生成して保存する",
            parameters: {
              type: "OBJECT",
              properties: {
                reason: { type: "STRING", description: "振り返りを行う理由" },
              },
              required: ["reason"],
            },
          },
        ],
      },
    ]
  end

  def execute_tool(name, args)
    case name
    when "semantic_search"
      execute_semantic_search(args["query"])
    when "conversation_reflection"
      execute_reflection(args["reason"])
    else
      { error: "Unknown tool: #{name}" }
    end
  end

  def execute_semantic_search(query)
    result = @context_retriever.retrieve(query)
    { results: result[:llm_context_prompt] }
  end

  def execute_reflection(reason)
    result = generate_reflection
    if result
      { success: true, file: result[:base_name], tags: result[:tags] }
    else
      { success: false, error: "振り返りの生成に失敗しました" }
    end
  end
end
