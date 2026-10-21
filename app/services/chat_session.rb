# 会話セッションの管理
# DB永続化されたメッセージ履歴を使い、記憶検索→プロンプト構築→LLM呼び出し→ログ記録を統合
class ChatSession
  attr_reader :character, :chat_logger

  # ChatSessionRecordから復元 or 新規作成
  def self.find_or_create(character, user, channel: nil, platform: nil, extra_tools: nil, extra_tool_executor: nil, extra_system_instruction: nil, extra_response_filter: nil)
    record = ChatSessionRecord.active
      .find_or_create_by!(character: character, user: user) do |r|
        r.status = "active"
        r.messages = []
      end
    new(character, record: record, channel: channel, platform: platform, extra_tools: extra_tools, extra_tool_executor: extra_tool_executor, extra_system_instruction: extra_system_instruction, extra_response_filter: extra_response_filter)
  end

  # 思考ループから送った連絡に返事をもらえる時間。この間に返事が来れば、連絡の続きとして会話する
  OUTGOING_REPLY_WINDOW = 60.minutes

  # 思考ループから連絡手段に送ったメッセージを、会話の履歴に入れる（進行中の会話がなければ始める）。
  # 返事が来たとき、何の話か分かるようにするため
  def self.record_outgoing(character, text)
    session = find_or_create(character, character.user)
    session.append_outgoing(text)
    ConversationTimeoutJob.set(wait: OUTGOING_REPLY_WINDOW).perform_later(session.record.id, session.record.message_count)
    session
  end

  def self.find_active(character, user, channel: nil, platform: nil, extra_tools: nil, extra_tool_executor: nil, extra_system_instruction: nil, extra_response_filter: nil)
    record = ChatSessionRecord.active.find_by(character: character, user: user)
    return nil unless record
    new(character, record: record, channel: channel, platform: platform, extra_tools: extra_tools, extra_tool_executor: extra_tool_executor, extra_system_instruction: extra_system_instruction, extra_response_filter: extra_response_filter)
  end

  # @param extra_tools [Array<Hash>, nil] アプリ層から追加するFunction Calling定義（functionDeclarationsの配列）
  # @param extra_tool_executor [Proc, nil] アプリ層のツール実行 lambda { |name, args| result_hash or nil }
  #   nilを返すとChatSession内蔵のツール（semantic_search）にフォールバック
  # @param extra_system_instruction [String, nil] PromptBuilder で生成された通常 system prompt の末尾に
  #   付け加える追加指示。MS のアダプタが capability 由来の出力形式指示を注入するために使う。
  # @param extra_response_filter [Proc, nil] LLM 応答テキストを ChatSessionRecord / ChatLogger に
  #   保存する前に通過させるフィルタ。例：sentinel タグ除去で履歴汚染を防ぐ。
  # @param platform [Symbol, nil] 会話の経路（:discord など）。プラグインがツールを出し分けるのに使う
  def initialize(character, record:, llm_client: nil, trigger_type: "user_message", channel: nil, platform: nil, extra_tools: nil, extra_tool_executor: nil, extra_system_instruction: nil, extra_response_filter: nil)
    @character = character
    @record = record
    @trigger_type = trigger_type
    @channel = channel
    @platform = platform
    @extra_tools = extra_tools
    @extra_tool_executor = extra_tool_executor
    @extra_system_instruction = extra_system_instruction
    @extra_response_filter = extra_response_filter
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

  # 会話ログは、すでに始まっている会話にだけ書く（思考ループの記録は思考ループのログに残っている）
  def append_outgoing(text)
    @record.append_message("model", text)
    @chat_logger.log_ai_message(text)
  end

  # claude -p で返答するか（MS のアダプタが、途中経過の返し方を選ぶのに使う）
  def use_claude_cli?
    ClaudeCli.enabled? && @extra_tools.nil? && @extra_tool_executor.nil?
  end

  # ユーザーメッセージを受けてAI応答を生成
  # @param on_progress [#call, nil] claude -p のとき、ツールを使う前に書いた文を途中経過として受け取る
  def send_message(user_message, on_progress: nil)
    # ログファイルが未作成なら作成
    @chat_logger.setup! unless @chat_logger.current_log_path
    @record.update!(full_log_path: @chat_logger.current_log_path) unless @record.full_log_path

    # ユーザーメッセージを記録
    @record.append_message("user", user_message)
    @chat_logger.log_user_message(user_message)

    # コンテキスト取得（記憶検索）
    context = build_context(user_message)

    # システムインストラクション構築
    system_instruction = build_system_instruction(context)

    # claude -p バックエンド。使えなければ返答できなかったことを返す（会話の履歴には残さない）
    if use_claude_cli?
      begin
        reply = send_via_claude(system_instruction, on_progress: on_progress)
      rescue ClaudeCli::Error => e
        Rails.logger.warn("[ChatSession] claude -p failed: #{e.message}") if defined?(Rails)
        return { response: ClaudeCli.failure_notice(e, what: "返答"), usage: nil }
      end
      @record.append_message("model", reply[:final])
      @chat_logger.log_ai_message(reply[:final])
      return { response: reply[:shown], usage: nil }
    end

    # Gemini API 用メッセージ構築
    gemini_messages = @record.messages.map do |m|
      { role: m["role"] == "user" ? "user" : "model", parts: [ { text: m["content"] } ] }
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
        Rails.logger.debug("[ChatSession] Tool call: #{fc[:name]}(#{fc[:args].to_json.slice(0, 100)})") if defined?(Rails)

        # ツールがFLに記録すべき会話を返した場合、記録する
        if tool_result.is_a?(Hash) && tool_result[:log]
          tool_result[:log].each { |entry| @chat_logger.log_ai_message(entry) }
        end

        api_response = tool_result.is_a?(Hash) ? tool_result.except(:log, :participant) : tool_result
        { name: fc[:name], response: api_response }
      end

      result = @llm_client.send_function_response(
        gemini_messages, function_responses,
        system_instruction: system_instruction, tools: tools
      )
    end

    ai_response = filter_response(result[:text])

    # AI応答を記録
    @record.append_message("model", ai_response)
    @chat_logger.log_ai_message(ai_response)

    {
      response: ai_response,
      usage: result[:usage]
    }
  end

  # ストリーミング版 send_message。テキストデルタが届いた時点で yield し、
  # 全ての Function Calling ループ完了後に { done: true, ... } を yield する。
  # 戻り値は同期版と同じ { response:, usage: }。
  # @yield [chunk] チャンクHash（{ delta: "..." } / { done: true, usage: ... }）
  def send_message_stream(user_message, tier: :main, &block)
    raise ArgumentError, "block required" unless block_given?

    @chat_logger.setup! unless @chat_logger.current_log_path
    @record.update!(full_log_path: @chat_logger.current_log_path) unless @record.full_log_path

    @record.append_message("user", user_message)
    @chat_logger.log_user_message(user_message)

    context = build_context(user_message)
    system_instruction = build_system_instruction(context)

    gemini_messages = @record.messages.map do |m|
      { role: m["role"] == "user" ? "user" : "model", parts: [ { text: m["content"] } ] }
    end

    tools = build_tool_definitions

    # 1st call: stream text deltas
    result = @llm_client.chat_stream(gemini_messages, system_instruction: system_instruction, tools: tools, tier: tier) do |delta|
      block.call(delta: delta)
    end

    # Function Calling ループ：ツール呼び出しがある間繰り返す。
    # 継続呼び出しもストリーミング。
    while result[:function_calls]&.any?
      gemini_messages << { role: "model", parts: result[:raw_parts] }

      function_responses = result[:function_calls].map do |fc|
        tool_result = execute_tool(fc[:name], fc[:args])
        Rails.logger.debug("[ChatSession] Tool call: #{fc[:name]}(#{fc[:args].to_json.slice(0, 100)})") if defined?(Rails)

        if tool_result.is_a?(Hash) && tool_result[:log]
          tool_result[:log].each { |entry| @chat_logger.log_ai_message(entry) }
        end

        api_response = tool_result.is_a?(Hash) ? tool_result.except(:log, :participant) : tool_result
        { name: fc[:name], response: api_response }
      end

      tool_response_content = {
        role: "user",
        parts: function_responses.map { |fr|
          { functionResponse: { name: fr[:name], response: fr[:response] } }
        }
      }
      gemini_messages = gemini_messages + [ tool_response_content ]

      result = @llm_client.chat_stream(gemini_messages, system_instruction: system_instruction, tools: tools, tier: tier) do |delta|
        block.call(delta: delta)
      end
    end

    ai_response = filter_response(result[:text])
    @record.append_message("model", ai_response)
    @chat_logger.log_ai_message(ai_response)

    block.call(done: true, usage: result[:usage])
    { response: ai_response, usage: result[:usage] }
  end

  # チャットリセット（振り返り生成 + セッションクリア）
  # @return [Hash, nil] { file_path:, base_name:, tags:, full_log_path: }
  def reset!
    reflection_result = nil
    full_log_path = @record.full_log_path || @chat_logger.current_log_path

    # 返事のなかった連絡だけの会話は振り返らない（思考ループが記憶に残している）
    if @record.message_count > 1 && full_log_path && @record.messages.any? { |m| m["role"] == "user" }
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

  # この会話で使えるツールの定義（Gemini の functionDeclarations 形式）。
  # claude -p のときは MCP サーバ（bin/memoria_mcp）がこれを使う
  def tool_definitions
    build_tool_definitions
  end

  def call_tool(name, args)
    execute_tool(name, args)
  end

  private

  DEEP_MODEL_TOOL = {
    name: "use_deep_model",
    description: "会話が、プログラミングや開発の相談、設計や技術的な壁打ち、込み入った作業の依頼になったときに呼ぶ。" \
      "この返答から、より強いモデルで考え直して応答する。この会話が終わるまで強いモデルのまま続く。" \
      "雑談や短いやりとりでは呼ばない",
    parameters: { type: "OBJECT", properties: { reason: { type: "STRING", description: "切り替える理由（短く）" } } }
  }.freeze

  # claude -p は返答ごとに1回動いて終わる。それを本人に知らせておかないと、
  # 「やっておくね」と書いたまま誰も作業しない、前の会話を探さない、ということが起きる
  CLAUDE_TURN_RULES = <<~TXT.freeze
    ## 返答と会話の仕組み
    - 返答（reply）を書くと、あなたの処理はいったん終わる。「やっておくね」と書くだけでは、その作業は誰もやらない
    - 返答のあとの動きを next_action で必ず選ぶ
      - wait_for_user: やると決めた作業を終えた。またはユーザーの返事や判断を待つ
      - continue: まだ続ける作業がある。返答はすぐユーザーに届き、あなたはすぐにまた起こされて next_step の作業を進める。長い作業を区切って途中経過を伝えるときにも使う
      - delegated: 作業を任せるツールや予定のツールで、もう動く形にした（終われば、あなたが起こされる）
    - 「進めるね」「やってくる」と書くなら continue か delegated にする。wait_for_user で終えるなら、この返答の中で終えた作業の結果か、ユーザーに求めることを書く
    - 会話はしばらく間が空くと閉じられ、次の会話はそれまでのやりとりなしで始まる。前の会話の全文は %{full_log_dir} に、始まった日時の名前（例: 20261020104536.md）で残っている。ユーザーが「さっき送った」「前に言った」と言ったときや、記憶にない情報が要るときは、まずそこを読む
  TXT

  # claude -p の返答の形。返答の本文と、返答のあとの動きを両方書かせる
  REPLY_SCHEMA = {
    type: "object",
    properties: {
      reply: { type: "string", description: "ユーザーに送る返答の本文" },
      next_action: {
        type: "string",
        enum: %w[wait_for_user continue delegated],
        description: "wait_for_user: 作業を終えた、またはユーザーを待つ / continue: すぐ続きの作業をする / delegated: ツールで任せた・予定に入れた",
      },
      next_step: { type: "string", description: "continue のとき、次にやる作業（具体的に）" },
    },
    required: %w[reply next_action],
  }.freeze

  # 1つのメッセージに対して、続けて動ける回数（止まらなくなるのを防ぐ）
  MAX_CONTINUATIONS = 5

  # アプリ層から差し込まれたツール（extra_tools）は MCP サーバの別プロセスでは使えないので、そのときは Gemini で動かす

  # @return [Hash] final: 最後の返答、shown: 呼び出し元が見せる文（途中経過を送れないときは、続けて動いた分もまとめる）
  def send_via_claude(system_instruction, on_progress: nil)
    # 途中経過も会話ログに残す
    progress = on_progress && lambda { |text|
      text = filter_response(text)
      @chat_logger.log_ai_message(text)
      on_progress.call(text)
    }

    earlier = []
    next_step = nil
    0.step do |continued|
      reply = reply_once(system_instruction, next_step: next_step, on_progress: progress)
      unless reply[:next_action] == "continue" && continued < MAX_CONTINUATIONS
        return { final: reply[:text], shown: [*earlier, reply[:text]].join("\n\n") }
      end

      # 続ける: いまの返答を先に届けて会話に残し、もう一度動かす
      @record.append_message("model", reply[:text])
      progress ? progress.call(reply[:text]) : @chat_logger.log_ai_message(reply[:text])
      earlier << reply[:text] unless progress
      next_step = reply[:next_step].presence || "直前の返答で進めると言った作業"
    end
  end

  def reply_once(system_instruction, next_step:, on_progress:)
    deep = @record.deep_mode
    run = run_claude(system_instruction, deep: deep, next_step: next_step, on_progress: on_progress)

    # 会話の途中で強いモデルに切り替えたら、この返答から作り直す
    run = run_claude(system_instruction, deep: true, next_step: next_step, on_progress: on_progress) if !deep && @record.reload.deep_mode

    # 決まった形で答えなかったときは、本文だけの返答として扱う
    answer = run.structured || {}
    {
      text: filter_response(answer["reply"].presence || run.text),
      next_action: answer["next_action"],
      next_step: answer["next_step"],
    }
  end

  def run_claude(system_instruction, deep:, next_step: nil, on_progress: nil)
    run = ClaudeCli::Runner.new.run(
      system_prompt: system_instruction,
      prompt: claude_prompt(next_step),
      json_schema: REPLY_SCHEMA,
      character: @character,
      scene: :chat,
      platform: @platform,
      model: ClaudeCli.model(deep: deep),
      trigger_type: @trigger_type,
      on_progress: on_progress
    )
    # ツールがFLに記録すべき会話を返した場合、記録する
    run.tool_events.each do |event|
      Array(event[:result][:log]).each { |entry| @chat_logger.log_ai_message(entry) }
    end
    run
  end

  # claude -p は1回ごとに独立して動くので、これまでの会話を書き起こしてプロンプトに入れる。
  # next_step があるときは、ユーザーのメッセージではなく、自分で決めた続きの作業で起こす
  def claude_prompt(next_step = nil)
    history = next_step ? messages : messages[0...-1]
    lines = []
    if history.any?
      lines << "これまでの会話:"
      history.each { |m| lines << "#{m[:role] == "user" ? "User" : llm_role_name}: #{m[:content]}" }
      lines << ""
    end
    if next_step
      lines << "Userからの新しいメッセージはない。直前の返答で続けると決めた作業:"
      lines << next_step
      lines << ""
      lines << "#{llm_role_name}として、この作業を進めてください。"
    else
      lines << "Userの新しいメッセージ:"
      lines << messages.last[:content].to_s
      lines << ""
      lines << "#{llm_role_name}として返答してください。"
    end
    lines << "返答の本文は reply に、返答のあとの動きは next_action に書いてください。"
    lines.join("\n")
  end

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

  # PromptBuilder で生成した system instruction の末尾に、
  # MS のアダプタが渡してきた追加指示を append する。
  def build_system_instruction(context)
    base = @prompt_builder.build(context: context, channel: @channel)
    plugin_segments = MemoriaServer::Plugin.prompt_segments(@character, scene: :chat)
    claude_segment = use_claude_cli? ? format(CLAUDE_TURN_RULES, full_log_dir: @vault.path_for(MemoriaCore::VaultManager::FL_DIR)) : nil
    [base, plugin_segments, claude_segment, @extra_system_instruction].map(&:to_s).reject(&:empty?).join("\n\n")
  end

  # LLM の生応答テキストを ChatSessionRecord / ChatLogger に保存する前に、
  # アダプタが渡してきたフィルタ（sentinel タグ除去等）を通す。
  # フィルタ未指定の場合は素通し。
  def filter_response(text)
    return text if @extra_response_filter.nil?
    @extra_response_filter.call(text)
  rescue => e
    Rails.logger.warn("[ChatSession] response filter failed: #{e.message}") if defined?(Rails)
    text
  end

  def build_context(user_message)
    retrieved = @context_retriever.retrieve(user_message)
    prospective = ProspectiveMemory.scan(@vault)
    schedules = build_schedule_context

    {
      retrieved_context: retrieved[:llm_context_prompt],
      narrative_summary: "",
      behavior_principles: load_behavior_principles,
      prospective_memory: prospective,
      upcoming_schedules: schedules
    }
  end

  def build_schedule_context
    schedules = @character.scheduled_wakeups.upcoming.limit(10).to_a +
      @character.scheduled_wakeups.proposed.order(:scheduled_at).to_a
    return "" if schedules.empty?
    schedules.map { |s| s.summary_line(with_id: true) }.join("\n")
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
            query: { type: "STRING", description: "検索クエリ" }
          },
          required: [ "query" ]
        }
      }
    ]

    # プラグインのツール
    base_fns += MemoriaServer::Plugin.gemini_declarations(@character, scene: :chat, platform: @platform)

    # claude -p のとき、強いモデルへの切り替え
    base_fns << DEEP_MODEL_TOOL if ClaudeCli.deep_model_available? && !@record.deep_mode

    # アプリ層から追加されたツール定義をマージ
    if @extra_tools
      @extra_tools.each do |tool_def|
        if tool_def[:functionDeclarations]
          base_fns += tool_def[:functionDeclarations]
        end
      end
    end

    [ { functionDeclarations: base_fns } ]
  end

  def execute_tool(name, args)
    # アプリ層のexecutorを先に試す
    if @extra_tool_executor
      result = @extra_tool_executor.call(name, args)
      return result if result
    end

    # プラグインのツール
    result = MemoriaServer::Plugin.execute(name, args, character: @character, scene: :chat, platform: @platform)
    return result if result

    # memoria内蔵ツール
    case name
    when "semantic_search"
      result = @context_retriever.retrieve(args["query"])
      { results: result[:llm_context_prompt] }
    when "use_deep_model"
      @record.update!(deep_mode: true)
      { switched: true, model: ClaudeCli.model(deep: true) }
    else
      { error: "Unknown tool: #{name}" }
    end
  end
end
