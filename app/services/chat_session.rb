# 会話セッションの管理
# DB永続化されたメッセージ履歴を使い、記憶検索→プロンプト構築→LLM呼び出し→ログ記録を統合
class ChatSession
  attr_reader :character, :chat_logger

  # ChatSessionRecordから復元 or 新規作成
  def self.find_or_create(character, user, channel: nil, extra_tools: nil, extra_tool_executor: nil)
    record = ChatSessionRecord.active
      .find_or_create_by!(character: character, user: user) do |r|
        r.status = "active"
        r.messages = []
      end
    new(character, record: record, channel: channel, extra_tools: extra_tools, extra_tool_executor: extra_tool_executor)
  end

  def self.find_active(character, user, channel: nil, extra_tools: nil, extra_tool_executor: nil)
    record = ChatSessionRecord.active.find_by(character: character, user: user)
    return nil unless record
    new(character, record: record, channel: channel, extra_tools: extra_tools, extra_tool_executor: extra_tool_executor)
  end

  # @param extra_tools [Array<Hash>, nil] アプリ層から追加するFunction Calling定義（functionDeclarationsの配列）
  # @param extra_tool_executor [Proc, nil] アプリ層のツール実行 lambda { |name, args| result_hash or nil }
  #   nilを返すとChatSession内蔵のツール（semantic_search）にフォールバック
  def initialize(character, record:, llm_client: nil, trigger_type: "user_message", channel: nil, extra_tools: nil, extra_tool_executor: nil)
    @character = character
    @record = record
    @trigger_type = trigger_type
    @channel = channel
    @extra_tools = extra_tools
    @extra_tool_executor = extra_tool_executor
    tracker = build_usage_tracker
    @llm_client = llm_client || LlmClient.new(usage_tracker: tracker)
    @vault = MemoriaCore::VaultManager.new(character.vault_path)
    @vault.ensure_structure!
    @embedding_store = MemoriaCore::EmbeddingStore.new(@vault, @llm_client)
    @embedding_store.initialize!
    @context_retriever = MemoriaCore::ContextRetriever.new(@vault, @embedding_store)
    @chat_logger = MemoriaCore::ChatLogger.new(@vault, llm_role_name)
    # DB上にログパスがあれば復元（セッション再開時に新しいFLを作らないようにする）
    @chat_logger.restore!(@record.full_log_path) if @record.full_log_path
    @prompt_builder = PromptBuilder.new(character)
  end

  def messages
    @record.messages.map { |m| m.symbolize_keys }
  end

  def record
    @record
  end

  # ユーザーメッセージを受けてAI応答を生成
  def send_message(user_message)
    # ログファイルが未作成なら作成
    @chat_logger.setup! unless @chat_logger.current_log_path
    @record.update!(full_log_path: @chat_logger.current_log_path) unless @record.full_log_path

    # ユーザーメッセージを記録
    @record.append_message("user", user_message)
    @chat_logger.log_user_message(user_message)

    # コンテキスト取得（記憶検索）
    context = build_context(user_message)

    # システムインストラクション構築
    system_instruction = @prompt_builder.build(context: context, channel: @channel)

    # Gemini API 用メッセージ構築
    gemini_messages = @record.messages.map do |m|
      { role: m["role"] == "user" ? "user" : "model", parts: [{ text: m["content"] }] }
    end

    # LLM呼び出し（Function Calling対応のツール定義）
    tools = build_tool_definitions
    result = @llm_client.chat(gemini_messages, system_instruction: system_instruction, tools: tools)

    # Function Call がある場合はループ処理
    while result[:function_calls]&.any?
      # raw_partsをそのまま使い、thought_signatureを保持
      gemini_messages << { role: "model", parts: result[:raw_parts] }

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
    @record.append_message("model", ai_response)
    @chat_logger.log_ai_message(ai_response)

    {
      response: ai_response,
      usage: result[:usage],
    }
  end

  # チャットリセット（振り返り生成 + セッションクリア）
  # @return [Hash, nil] { file_path:, base_name:, tags:, full_log_path: }
  def reset!
    reflection_result = nil
    full_log_path = @record.full_log_path || @chat_logger.current_log_path

    if @record.message_count > 1 && full_log_path
      conversation_text = @record.messages.map { |m|
        speaker = m["role"] == "user" ? "User" : llm_role_name
        "#{speaker}: #{m["content"]}"
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

        @chat_logger.update_frontmatter(
          "title" => File.basename(reflection_result[:base_name]).sub(/\ASN-\d+-/, "").tr("_", " "),
          "summary_note" => "[[#{reflection_result[:base_name]}.md]]"
        )
      end
    end

    # セッションをクローズしてDBに永続化
    @record.close!
    @chat_logger.reset!

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
    retrieved = @context_retriever.retrieve(user_message)
    prospective = scan_action_items

    {
      retrieved_context: retrieved[:llm_context_prompt],
      narrative_summary: "",
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

  # --- Function Calling ---

  def build_tool_definitions
    base_fns = [
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
    ]

    # アプリ層から追加されたツール定義をマージ
    if @extra_tools
      @extra_tools.each do |tool_def|
        if tool_def[:functionDeclarations]
          base_fns += tool_def[:functionDeclarations]
        end
      end
    end

    [{ functionDeclarations: base_fns }]
  end

  def execute_tool(name, args)
    # アプリ層のexecutorを先に試す
    if @extra_tool_executor
      result = @extra_tool_executor.call(name, args)
      return result if result
    end

    # memoria内蔵ツール
    case name
    when "semantic_search"
      result = @context_retriever.retrieve(args["query"])
      { results: result[:llm_context_prompt] }
    else
      { error: "Unknown tool: #{name}" }
    end
  end
end
