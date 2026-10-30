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
  def initialize(character, record:, llm_client: nil, trigger_type: "user_message", channel: nil, platform: nil, extra_tools: nil, extra_tool_executor: nil, extra_system_instruction: nil, extra_response_filter: nil, turn_wait: nil)
    @character = character
    @turn_wait = turn_wait
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
    with_turn_lock do
      @record.append_message("model", text)
      @chat_logger.log_ai_message(text)
    end
  end

  # claude -p で返答するか（MS のアダプタが、途中経過の返し方を選ぶのに使う）
  def use_claude_cli?
    ClaudeCli.enabled? && @extra_tools.nil? && @extra_tool_executor.nil?
  end

  # ユーザーメッセージを受けてAI応答を生成
  # @param on_progress [#call, nil] claude -p のとき、ツールを使う前に書いた文を途中経過として受け取る
  def send_message(user_message, on_progress: nil)
    with_turn_lock { answer_message(user_message, on_progress: on_progress) }
  end

  # claude -p の構造化返答に capability の項目（表情など）を足し、使い方の指示を system prompt に加える。
  # セッションはリクエストごとに作るので、足した分はそのリクエストだけに効く。claude -p 以外では何もしない
  def add_reply_capabilities(capabilities)
    return unless use_claude_cli?

    @reply_capabilities = Array(capabilities).select(&:reply_schema)
    return if @reply_capabilities.empty?

    @extra_system_instruction = [@extra_system_instruction, *@reply_capabilities.map(&:prompt_segment)].map(&:to_s).reject(&:empty?).join("\n\n")
  end

  # ユーザーの発言ではない出来事（任せた作業が終わった、予定の時刻になったなど）を、続いている会話の中で受けて話す。
  # 会話の外で考えると、会話で言ったことを知らないまま同じ報告を繰り返したり、済んだ話を始め直したりする。
  # 出来事そのものは履歴に入れず、話したことだけを入れる。claude -p でだけ使える
  # @return [Hash] response: 伝える文（続けて動いた分も含む）
  def send_event(event)
    raise ArgumentError, "send_event needs the claude -p backend" unless use_claude_cli?

    with_turn_lock do
      @chat_logger.setup! unless @chat_logger.current_log_path
      @record.update!(full_log_path: @chat_logger.current_log_path) unless @record.full_log_path

      context = begin_claude_turn(event)
      system_instruction = build_system_instruction(context, dynamic: !persistent_claude?)
      reply = send_via_claude(system_instruction, event: event)
      @record.append_message("model", reply[:final], work: reply[:work])
      note_persistent_seen
      @chat_logger.log_ai_message(reply[:final])
      { response: reply[:shown] }
    end
  end

  def answer_message(user_message, on_progress: nil)
    # ログファイルが未作成なら作成
    @chat_logger.setup! unless @chat_logger.current_log_path
    @record.update!(full_log_path: @chat_logger.current_log_path) unless @record.full_log_path

    # ユーザーメッセージを記録
    @record.append_message("user", user_message)
    @chat_logger.log_user_message(user_message)

    # コンテキスト取得（記憶検索）
    context = build_context(user_message)
    @turn_context = context
    @persistent_key = nil

    # システムインストラクション構築（常駐の claude には、毎回変わる節を入れない。毎ターンの user メッセージに添える）
    system_instruction = build_system_instruction(context, dynamic: !persistent_claude?)

    # claude -p バックエンド。使えなければ返答できなかったことを返す（会話の履歴には残さない）
    if use_claude_cli?
      begin
        reply = send_via_claude(system_instruction, on_progress: on_progress)
      rescue ClaudeCli::Error => e
        Rails.logger.warn("[ChatSession] claude -p failed: #{e.message}") if defined?(Rails)
        return { response: ClaudeCli.failure_notice(e, what: "返答"), usage: nil }
      end
      @record.append_message("model", reply[:final], work: reply[:work])
      note_persistent_seen
      @chat_logger.log_ai_message(reply[:final])
      return { response: reply[:shown], usage: nil, extras: reply[:extras] }
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

    with_turn_lock { stream_message(user_message, tier: tier, &block) }
  end

  def stream_message(user_message, tier:, &block)
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
  # 返答の途中で閉じて、あとの発言が閉じた記録に入らないよう、返答と同じ順番待ち（ロック）の中で行う。
  # @param expected_message_count [Integer, nil] 指定したときは、ロックを取ったあとの記録の発言数が
  #   これと違えば（待っている間に新しい発言があった）、何もせず nil を返す
  def reset!(expected_message_count: nil)
    with_turn_lock { reset_locked!(expected_message_count) }
  end

  def reset_locked!(expected_message_count)
    return nil if expected_message_count && @record.message_count != expected_message_count

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

  private :answer_message, :stream_message, :reset_locked!

  # 1人のキャラクターは一度に1つのことしか話さない。ユーザーへの返答、出来事への応答、送った連絡の記録を順番に処理する。
  # 同時に動くと、片方がもう片方の発言を知らないまま話し、履歴の保存でもう片方の発言を消すこともある。
  # Discord・ジョブ・API は別のプロセスなので、ファイルロックで並べる
  TURN_LOCK_WAIT = 30.minutes

  TurnBusy = TurnLock::Busy

  private

  def with_turn_lock(&block)
    nested = TurnLock.held.include?(@character.id)
    TurnLock.new(@character.id, label: @character.name, wait: @turn_wait || TURN_LOCK_WAIT).synchronize do
      # 待っている間にほかの発言が足されているかもしれないので、読み直してから話す
      @record.reload if !nested && @record.persisted?
      block.call
    end
  end

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

  # @return [Hash] final: 最後の返答、shown: 呼び出し元が見せる文（途中経過を送れないときは、続けて動いた分もまとめる）、
  #   work: 最後の返答を書くまでにした作業の記録
  # 返答の構造化出力の形。capability の項目を足していれば、その項目も必須にする
  def reply_schema
    return REPLY_SCHEMA if @reply_capabilities.blank?

    extra = @reply_capabilities.reduce({}) { |fields, capability| fields.merge(capability.reply_schema) }
    REPLY_SCHEMA.merge(
      properties: REPLY_SCHEMA[:properties].merge(extra),
      required: REPLY_SCHEMA[:required] + extra.keys.map(&:to_s),
    )
  end

  # 構造化返答から、capability の値を取り出す（取れなかった capability は含めない）
  def reply_extras(answer)
    Array(@reply_capabilities).each_with_object({}) do |capability, extras|
      value = capability.parse_value(answer)
      extras[capability.name] = value unless value.nil?
    end
  end

  def send_via_claude(system_instruction, on_progress: nil, event: nil)
    # 途中経過も会話ログに残す
    progress = on_progress && lambda { |text|
      text = filter_response(text)
      @chat_logger.log_ai_message(text)
      on_progress.call(text)
    }

    earlier = []
    # 先に届けて会話に残す（最後の返答は呼び出し元が届けて残す）
    tell = lambda { |text, work|
      @record.append_message("model", text, work: work)
      note_persistent_seen
      progress ? progress.call(text) : @chat_logger.log_ai_message(text)
      earlier << text unless progress
    }
    next_step = nil
    0.step do |continued|
      reply = reply_once(system_instruction, next_step: next_step, event: continued.zero? ? event : nil, on_progress: progress)
      # 答えのあとに裏の作業が終わって報告したときは、答え・報告の順に届ける。作業の記録は最初の返答に添える
      *before, text = [reply[:text], *reply[:followups]]
      work = reply[:work]
      before.each do |said|
        tell.call(said, work)
        work = nil
      end
      unless reply[:next_action] == "continue" && continued < MAX_CONTINUATIONS
        return { final: text, shown: [*earlier, text].join("\n\n"), work: work, extras: reply[:extras] }
      end

      # 続ける: いまの返答を先に届けて会話に残し、もう一度動かす
      tell.call(text, work)
      next_step = reply[:next_step].presence || "直前の返答で進めると言った作業"
    end
  end

  def reply_once(system_instruction, next_step:, on_progress:, event: nil)
    deep = @record.deep_mode
    run = run_claude(system_instruction, deep: deep, next_step: next_step, event: event, on_progress: on_progress)
    work = work_log(run)

    # 会話の途中で強いモデルに切り替えたら、この返答から作り直す（作り直す前にした作業も済んでいるので残す）
    if !deep && @record.reload.deep_mode
      run = run_claude(system_instruction, deep: true, next_step: next_step, event: event, on_progress: on_progress)
      work += work_log(run)
    end

    # 決まった形で答えなかったときは、本文だけの返答として扱う
    answer = run.structured || {}
    # 答えのあと裏の作業が終わって出した答え。伝えることがなく reply を空にしたものは届けない。
    # 次の動きは、最後に出した答えのものに従う
    followups = run.followups.to_a.filter_map do |f|
      text = f[:structured] ? f[:structured]["reply"].to_s : f[:text].to_s
      answer = f[:structured] if f[:structured]
      filter_response(text).presence
    end
    {
      text: filter_response(run.structured&.dig("reply").presence || run.text),
      followups: followups,
      next_action: answer["next_action"],
      next_step: answer["next_step"],
      extras: reply_extras(answer),
      work: work,
    }
  end

  def work_log(run)
    run.tool_events.flat_map { |event| Array(event[:result][:log]).map(&:to_s) }
  end

  def run_claude(system_instruction, deep:, next_step: nil, event: nil, on_progress: nil)
    run = ClaudeCli::Runner.new.run(
      system_prompt: system_instruction,
      prompt: claude_prompt(next_step, event),
      json_schema: reply_schema,
      character: @character,
      scene: :chat,
      platform: @platform,
      model: ClaudeCli.chat_model(deep: deep),
      trigger_type: @trigger_type,
      on_progress: on_progress,
      persistence: persistence_for(next_step, event)
    )
    @persistent_key = run.session_key
    # ツールがFLに記録すべき会話を返した場合、記録する
    run.tool_events.each do |event|
      Array(event[:result][:log]).each { |entry| @chat_logger.log_ai_message(entry) }
    end
    run
  end

  # --- 会話のあいだ claude -p を起動したままにする（CLAUDE_CLI_PERSISTENT=1）---
  #
  # 常駐の claude は、会話の記録（ChatSessionRecord）ごとに1本。最初のターン（と、起動し直したとき）は会話の全文を渡し、
  # 以降は「毎回変わる状況・常駐の claude が知らない発言・新しいメッセージ」だけを渡す。
  # 常駐の claude が見た会話の範囲（seen）は、返答を会話の記録に追記するたびに覚えさせる。履歴と合わなくなったら
  # （別のプロセスが会話に書き足した、記録が変わった）、その claude は捨てて、履歴から起動し直す。

  def persistent_claude?
    use_claude_cli? && ClaudeCli.persistent?
  end

  # claude を動かす前の準備（毎ターン変わる状況を覚え、前のターンの常駐の鍵を忘れる）
  def begin_claude_turn(trigger)
    @persistent_key = nil
    @turn_context = build_context(trigger)
  end

  def persistence_for(next_step, event)
    return nil unless persistent_claude? && @turn_context

    {
      record_id: @record.id,
      verify: ->(seen) { persistent_history_ok?(seen) },
      fresh_prompt: -> { claude_prompt(next_step, event, background: background_block(prospective: true, schedules: true, memory: true)) },
      resume_prompt: ->(seen) { persistent_resume_prompt(seen, next_step, event) }
    }
  end

  # 常駐の claude が見た範囲が、いまの会話の履歴の先頭部分と同じか（会話は追記しかされないので、数と最後の1件で足りる）
  def persistent_history_ok?(seen)
    return false unless seen.is_a?(Hash) && seen[:count].to_i.positive?

    all = messages
    seen[:count] <= all.size && message_digest(all[seen[:count] - 1]) == seen[:tail]
  end

  def persistent_resume_prompt(seen, next_step, event)
    unseen = messages[seen[:count]..] || []
    # 最後は、いま届いた User のメッセージ（プロンプトの末尾で渡す）。出来事・続きの作業のときは、全部が知らない発言
    unseen = unseen[0...-1] unless next_step || event
    background = background_block(
      prospective: changed_state(@turn_context[:prospective_memory], seen[:prospective]),
      schedules: changed_state(@turn_context[:upcoming_schedules], seen[:schedules]),
      memory: !(next_step || event) # 続きの作業・出来事で起こすときは、同じ記憶を繰り返さない
    )
    lines = background.lines.map(&:chomp) + [ "" ]
    lines.concat(history_lines(unseen, "前に渡した会話のあとに、別の場所であった会話（あなたの返答を含む）:"))
    lines.concat(prompt_tail_lines(next_step, event))
    lines.join("\n")
  end

  # 毎ターン変わる状況（時刻・記憶・予定など）。system prompt の代わりに、user メッセージの先頭に添える。
  # 予定と前向き記憶は、前に添えたものから変わったときだけ添える（古いものが積み重ならないように）
  def background_block(prospective:, schedules:, memory:)
    body = @prompt_builder.build_dynamic(context: @turn_context, prospective: prospective, schedules: schedules, memory: memory)
    <<~TEXT.chomp
      【システムが添えた背景。Userの発言ではない。会話の流れを変えず、必要なときだけ参照する。
      予定と前向き記憶は、前に添えたものから変わったときだけ添える。添えたものが最新で、前のものは古い】
      #{body}
      【背景ここまで】
    TEXT
  end

  # 返答を会話の記録に追記したあと、常駐の claude が見た範囲を、いまの履歴の終わりまでに進める
  def note_persistent_seen
    return unless @persistent_key && @turn_context

    session = PersistentClaude::Pool.instance.fetch(@persistent_key)
    return unless session

    all = messages
    session.seen = {
      count: all.size, tail: message_digest(all.last),
      prospective: text_digest(@turn_context[:prospective_memory]), schedules: text_digest(@turn_context[:upcoming_schedules])
    }
  end

  # 前に添えたものから変わっていれば、添える（true）。空になったのなら、なくなったと伝える（:cleared）。変わっていなければ添えない（false）
  def changed_state(text, seen_digest)
    return false if text_digest(text) == seen_digest

    text.to_s.empty? ? :cleared : true
  end

  def message_digest(message)
    message && text_digest("#{message[:role]}\u0000#{message[:content]}")
  end

  def text_digest(text)
    Digest::SHA256.hexdigest(text.to_s)[0, 16]
  end

  # claude -p は1回ごとに独立して動くので、これまでの会話を書き起こしてプロンプトに入れる。
  # next_step があるときは、ユーザーのメッセージではなく、自分で決めた続きの作業で起こす。
  # event があるときは、ユーザーのメッセージではなく、起きた出来事で起こす
  def claude_prompt(next_step = nil, event = nil, background: nil)
    history = next_step || event ? messages : messages[0...-1]
    lines = []
    lines.concat(background.to_s.lines.map(&:chomp) + [ "" ]) if background.present?
    lines.concat(history_lines(history, "これまでの会話:"))
    lines.concat(prompt_tail_lines(next_step, event))
    lines.join("\n")
  end

  # 会話の書き起こし。返答の前にした作業も書き起こす（ファイルの場所やコマンドを、次の返答で調べ直さずに済むように）
  def history_lines(history, heading)
    return [] if history.empty?

    lines = [ heading ]
    history.each do |m|
      if m[:role] == "user"
        lines << "User: #{m[:content]}"
      else
        Array(m[:work]).each { |entry| lines << "（#{llm_role_name}の作業）#{entry}" }
        lines << "#{llm_role_name}: #{m[:content]}"
      end
    end
    if history.any? { |m| m[:work].present? }
      lines << "（#{llm_role_name}の作業）の行は、あなたがその返答の前に実際にしたこと。" \
        "そこに出てくるファイルの場所やコマンドはそのまま使い、同じ下調べを繰り返さない。"
    end
    lines << ""
    lines
  end

  # プロンプトの末尾: 何で起こされたか（出来事・続きの作業・Userのメッセージ）と、返答の形
  def prompt_tail_lines(next_step, event)
    lines = []
    if event
      lines << "Userからの新しいメッセージはない。いま、次の出来事であなたが起こされた:"
      lines << event
      lines << ""
      lines << "#{llm_role_name}として、上の会話の続きで、この出来事をUserに伝えてください。" \
        "これまでの会話ですでに伝えたことは繰り返さず、新しく分かったことだけを伝える。" \
        "会話の中ですでに済んだ話を、始め直さない。"
    elsif next_step
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
    lines << "返答のあと、裏で走らせた作業が終わった知らせで起こされたときは、分かった結果を reply で報告する。" \
      "新しく伝えることがなければ reply を空にする（返答で言ったことを繰り返さない）。"
    lines
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
  # @param dynamic [Boolean] false のとき、毎回変わる節（時刻・記憶・予定など）を入れない（常駐の claude は、system prompt を最初に1回しか渡せない）
  def build_system_instruction(context, dynamic: true)
    base = @prompt_builder.build(context: context, channel: @channel, dynamic: dynamic)
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
