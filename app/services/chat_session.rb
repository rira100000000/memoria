# 会話セッションの管理
# インメモリでメッセージ履歴を保持し、記憶検索→プロンプト構築→LLM呼び出し→ログ記録を統合
class ChatSession
  # messages: [{ role: "user"/"model", content: "..." }]
  attr_reader :messages, :character, :chat_logger

  def initialize(character, llm_client: nil, trigger_type: "user_message")
    @character = character
    @trigger_type = trigger_type
    tracker = build_usage_tracker
    @llm_client = llm_client || LlmClient.new(usage_tracker: tracker)
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
  # @return [Hash, nil] { file_path:, base_name:, tags:, full_log_path: }
  def reset!
    reflection_result = nil
    full_log_path = @chat_logger.current_log_path

    if @messages.length > 1 && full_log_path
      conversation_text = @messages.map { |m|
        speaker = m[:role] == "user" ? "User" : llm_role_name
        "#{speaker}: #{m[:content]}"
      }.join("\n\n")

      service = ReflectionService.new(@character, llm_client: @llm_client)
      timestamp = MemoriaCore::FlStore.extract_timestamp(@chat_logger.log_file_name || "")
      reflection_result = service.generate(
        conversation_text: conversation_text,
        full_log_ref: @chat_logger.log_file_name || "",
        timestamp: timestamp
      )

      if reflection_result
        reflection_result[:full_log_path] = full_log_path

        # FullLogのfrontmatter更新
        @chat_logger.update_frontmatter(
          "title" => File.basename(reflection_result[:base_name]).sub(/\ASN-\d+-/, "").tr("_", " "),
          "summary_note" => "[[#{reflection_result[:base_name]}.md]]"
        )
      end
    end

    @chat_logger.reset!
    @messages = []
    @narrative_summary = ""
    @first_message = true

    reflection_result
  end

  private

  def build_usage_tracker
    character = @character
    trigger_type = @trigger_type
    lambda { |model, usage|
      begin
        ApiUsageLog.record!(
          user: character.user,
          character: character,
          trigger_type: trigger_type,
          llm_model: model,
          usage: usage
        )
      rescue => e
        Rails.logger.warn("[ChatSession] Usage tracking failed: #{e.message}") if defined?(Rails)
      end
    }
  end

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

  # generate_reflection, build_reflection_prompt, parse_reflection_response は
  # ReflectionService に移動済み

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
