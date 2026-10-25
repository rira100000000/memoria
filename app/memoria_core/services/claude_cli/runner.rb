require "open3"
require "tmpdir"

module ClaudeCli
  # claude -p を1回実行する。
  #
  # キャラクターを指定したときは、そのツールを MCP サーバ（bin/memoria_mcp）として渡す。
  # MCP サーバは実行したツールの記録を一時ファイル（JSON Lines）に書き、ここで読み戻して返す。
  # Claude Code の組み込みツールは、既定では読むだけのもの（WebSearch・WebFetch）をキャラクターのツールと
  # 一緒に使わせる。CLAUDE_CLI_BUILTIN_TOOLS=default にすると全部使わせる（権限は CLAUDE_CLI_SETTINGS の
  # 設定ファイルで決める）。キャラクターごとに変えるときは CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER に
  # "vault_dir_name=ツール,ツール;vault_dir_name=default" の形で書く（"vault_dir_name=" なら使わせない）。
  # 作業ディレクトリは CLAUDE_CLI_WORKDIR（未設定なら空の一時ディレクトリ）。
  # 出力が CLAUDE_CLI_IDLE_TIMEOUT 秒とぎれたら止める。キャラクターが long_think ツールで長考を宣言したら、
  # その期限までは出力がなくても止めない。経過時間の上限 CLAUDE_CLI_TIMEOUT は安全弁として残す。
  # 利用者の Claude Code の設定ファイル（~/.claude など）は読まない。
  class Runner
    Result = Struct.new(:text, :tool_events, :model, :structured, keyword_init: true)

    # 経過時間の上限（安全弁）
    DEFAULT_TIMEOUT = 7200
    # 出力がこれだけとぎれたら止める
    DEFAULT_IDLE_TIMEOUT = 600
    # 止まっていないかを見る間隔
    POLL_INTERVAL = 1
    DEFAULT_MAX_TURNS = 20
    # キャラクターのツールと一緒に使わせる Claude Code の組み込みツール（読むだけのもの）
    DEFAULT_BUILTIN_TOOLS = "WebSearch,WebFetch"
    # 組み込みツールの呼び出しを記録するときの名前（Web検索は Gemini のときと同じ名前にそろえる）
    BUILTIN_EVENT_NAMES = { "WebSearch" => "web_search", "WebFetch" => "web_fetch" }.freeze
    # 組み込みツールの入力のうち、記録に残すもの
    BUILTIN_EVENT_ARGS = %w[query url command file_path path pattern description].freeze
    BUILTIN_RESULT_CHARS = 1000

    def initialize(command: ENV.fetch("CLAUDE_CLI_COMMAND", "claude"),
                   timeout: ENV.fetch("CLAUDE_CLI_TIMEOUT", DEFAULT_TIMEOUT).to_i,
                   idle_timeout: ENV.fetch("CLAUDE_CLI_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT).to_i,
                   poll_interval: POLL_INTERVAL,
                   max_turns: ENV.fetch("CLAUDE_CLI_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
                   builtin_tools: ENV.fetch("CLAUDE_CLI_BUILTIN_TOOLS", DEFAULT_BUILTIN_TOOLS),
                   builtin_tools_by_character: ENV["CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER"],
                   work_dir: ENV["CLAUDE_CLI_WORKDIR"].presence,
                   settings: ENV["CLAUDE_CLI_SETTINGS"].presence,
                   mcp_command: Rails.root.join("bin/memoria_mcp").to_s)
      @command = command
      @work_dir = work_dir
      @settings = settings
      @builtin_tools = tool_list(builtin_tools)
      @builtin_tools_by_character = builtin_tools_by_character.to_s.split(";").filter_map { |entry|
        key, tools = entry.split("=", 2)
        [key.strip, tool_list(tools)] if key.to_s.strip.present? && tools
      }.to_h
      @timeout = timeout
      @idle_timeout = idle_timeout
      @poll_interval = poll_interval
      @max_turns = max_turns
      @mcp_command = mcp_command
    end

    # @param character [Character, nil] 指定するとそのキャラクターのツールを MCP で渡す。nil ならツールなし
    # @param scene [Symbol] :chat / :thinking（MCP サーバが出すツールが変わる）
    # @param trigger_type [String] ツール内の Gemini 呼び出し（埋め込みなど）を ApiUsageLog に記録するときの区分
    # @param on_progress [#call, nil] ツールを使う前に書いた文（「調べてみるね」など）を、終わるのを待たずに受け取る
    # @param json_schema [Hash, nil] 指定すると、この形で答えさせる（Result#structured に入る）
    # @param usage_context [Hash, nil] ツールの使用記録（ToolUsageLog）に添える場面の情報（予定の { wakeup_id:, purpose: }）
    # @return [Result] text: 最終応答、tool_events: [{ name:, args:, result: }]、structured: json_schema の形の答え
    def run(system_prompt:, prompt:, model:, character: nil, scene: nil, trigger_type: nil, platform: nil, on_progress: nil, json_schema: nil, usage_context: nil)
      Dir.mktmpdir("memoria-claude") do |dir|
        events_path = File.join(dir, "tool_events.jsonl")
        long_think = LongThink.new(File.join(dir, "long_think.json"))
        work_dir = File.join(dir, "work")
        Dir.mkdir(work_dir)

        config_path = nil
        if character
          config_path = File.join(dir, "mcp.json")
          File.write(config_path, JSON.generate(mcp_config(character, scene, platform, trigger_type, events_path, long_think, usage_context)))
        end

        # キャラクターとして動くときだけ、指定された作業ディレクトリで動かす（軽い作業は空のディレクトリ）
        work_dir = @work_dir if character && @work_dir
        relay = on_progress && ProgressRelay.new(on_progress)
        builtin = character ? @builtin_tools_by_character.fetch(character.vault_dir_name, @builtin_tools) : []
        stdout, stderr, status = execute(command_line(system_prompt, model, config_path, builtin, json_schema), prompt, work_dir, relay,
          long_think: character && long_think)
        messages = parse_stream(stdout)
        text = final_text(messages, stdout, stderr, status)
        structured = messages.reverse.find { |m| m["type"] == "result" }&.dig("structured_output")

        Result.new(text: text, tool_events: read_events(events_path) + builtin_events(messages), model: model,
                   structured: structured.is_a?(Hash) ? structured : nil)
      end
    end

    private

    def mcp_config(character, scene, platform, trigger_type, events_path, long_think, usage_context = nil)
      args = ["--character", character.id.to_s, "--scene", scene.to_s]
      args += ["--trigger", trigger_type] if trigger_type
      args += ["--platform", platform.to_s] if platform
      env = { "MEMORIA_MCP_EVENTS" => events_path, "MEMORIA_MCP_LONG_THINK" => long_think.path, "RAILS_ENV" => Rails.env.to_s }
      env["MEMORIA_MCP_CONTEXT"] = JSON.generate(usage_context) if usage_context.present?
      {
        mcpServers: {
          memoria: {
            command: @mcp_command,
            args: args,
            env: env,
          },
        },
      }
    end

    def tool_list(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def command_line(system_prompt, model, config_path, builtin, json_schema = nil)
      cmd = [
        @command, "-p",
        "--output-format", "stream-json", "--verbose",
        "--model", model,
        "--system-prompt", system_prompt,
        "--tools", builtin.join(","),
        "--strict-mcp-config",
        "--setting-sources", "",
        "--no-session-persistence",
        "--max-turns", @max_turns.to_s
      ]
      cmd += ["--json-schema", JSON.generate(json_schema)] if json_schema
      if config_path
        # "default"（全部）のときの許可は設定ファイルの権限に任せ、個別に名前を挙げたものだけ許可に足す
        allowed = builtin == ["default"] ? [] : builtin
        cmd += ["--mcp-config", config_path, "--allowedTools", "mcp__memoria", *allowed]
        cmd += ["--settings", @settings] if @settings
      end
      cmd
    end

    # プロンプトは長くなるので標準入力で渡す。出力がとぎれたとき（長考の宣言中を除く）と、経過時間の上限を
    # 超えたときは、プロセスグループごと止める（claude が起動した MCP サーバも残さない）
    def execute(cmd, prompt, work_dir, relay = nil, long_think: nil)
      Open3.popen3(*cmd, chdir: work_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        # ロケールに関係なく UTF-8 として読み書きする（LANG のない環境では ASCII として扱われ、日本語で壊れる）
        [stdin, stdout, stderr].each { |io| io.set_encoding(Encoding::UTF_8) }
        activity = Activity.new
        readers = []
        begin
          readers << Thread.new do
            out = +""
            stdout.each_line do |line|
              activity.touch
              out << line
              relay&.feed(line)
            end
            out
          end
          readers << Thread.new { stderr.read }
          stdin.write(prompt)
          stdin.close

          watch(wait_thr, activity, relay, long_think)
          [readers[0].value, readers[1].value, wait_thr.value]
        ensure
          # 止めたとき・例外のとき: 残ったプロセスと読み取りのスレッドを片づける
          if wait_thr.alive?
            kill_group(wait_thr)
            readers.each { |t| t.join(1) || t.kill }
          end
        end
      end
    rescue Errno::ENOENT
      raise Error, "#{@command} コマンドが見つかりません"
    end

    # 終わるまで見張る。止めるべきときは Error を上げる（プロセスは execute の ensure で止める）
    def watch(wait_thr, activity, relay, long_think)
      started = monotonic_now
      announced = nil
      until wait_thr.join(@poll_interval)
        declaration = long_think&.read
        if declaration && declaration != announced
          announced = declaration
          relay&.notify("長考中（〜#{declaration.minutes}分：#{declaration.reason}）")
        end

        if monotonic_now - started > @timeout
          raise Error, "#{duration_text(@timeout)}たっても終わらなかったので止めました"
        end
        next if declaration && Time.now < declaration.until_time

        idle = activity.idle_seconds
        # 長考の期限が過ぎたばかりなら、そこから数え直す（期限の直後に止めない）
        idle = [idle, Time.now - declaration.until_time].min if declaration
        raise Error, "#{duration_text(@idle_timeout)}出力がなかったので止めました" if idle > @idle_timeout
      end
    end

    def duration_text(seconds)
      return "#{seconds / 3600}時間" if seconds >= 3600 && (seconds % 3600).zero?
      return "#{seconds / 60}分" if seconds >= 60 && (seconds % 60).zero?

      "#{seconds}秒"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def kill_group(wait_thr)
      Process.kill("TERM", -wait_thr.pid)
      wait_thr.join(2)
      Process.kill("KILL", -wait_thr.pid)
    rescue Errno::ESRCH
      nil
    end

    # 最後に出力があった時刻（読み取りのスレッドが書き、見張る側が読む）
    class Activity
      def initialize
        @mutex = Mutex.new
        @last = now
      end

      def touch
        @mutex.synchronize { @last = now }
      end

      def idle_seconds
        now - @mutex.synchronize { @last }
      end

      private

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # stream-json を1行ずつ受け取り、ツールを使う前に書いた文を途中経過として渡す。
    # 最終応答は result の行から取るので、ここでは渡さない（ツールを使う前の文だけが途中経過になる）。
    # サブエージェントの文（parent_tool_use_id があるもの）も渡さない
    class ProgressRelay
      # json_schema を指定したとき、claude -p が答えを返すのに使うツール
      STRUCTURED_OUTPUT_TOOL = "StructuredOutput"

      def initialize(callback)
        @callback = callback
        @pending = []
        @mutex = Mutex.new
      end

      def feed(line)
        @mutex.synchronize { feed_line(line) }
      end

      # 出力とは別に、知らせたいことを途中経過として渡す（長考の宣言など）
      def notify(text)
        @mutex.synchronize { deliver([text]) }
      end

      private

      def feed_line(line)
        return unless line.strip.start_with?("{")

        m = JSON.parse(line)
        return unless m["type"] == "assistant" && m["message"].is_a?(Hash) && m["parent_tool_use_id"].nil?

        Array(m["message"]["content"]).each do |c|
          next unless c.is_a?(Hash)

          if c["type"] == "text" && c["text"].to_s.strip.present?
            @pending << c["text"].strip
          elsif c["type"] == "tool_use" && c["name"] == STRUCTURED_OUTPUT_TOOL
            # 決まった形の答えを返す直前の文は途中経過ではない（答えの中身が返答になる）
            @pending = []
          elsif c["type"] == "tool_use"
            flush
          end
        end
      rescue JSON::ParserError
        nil
      end

      def flush
        texts = @pending
        @pending = []
        deliver(texts)
      end

      def deliver(texts)
        texts.each { |text| @callback.call(text) }
      rescue => e
        Rails.logger.warn("[ClaudeCli] progress callback failed: #{e.message}")
      end
    end

    # stream-json の各行（JSON）を読む。JSON でない行は飛ばす
    def parse_stream(stdout)
      stdout.to_s.each_line.filter_map do |line|
        JSON.parse(line) if line.strip.start_with?("{")
      rescue JSON::ParserError
        nil
      end
    end

    def final_text(messages, stdout, stderr, status)
      result = messages.reverse.find { |m| m["type"] == "result" }
      unless result
        detail = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "出力なし"
        raise Error, "終了コード #{status&.exitstatus}: #{detail.truncate(300)}"
      end
      if result["is_error"] || result["subtype"] != "success"
        reason = result["result"].presence || result["subtype"] || "不明なエラー"
        raise Error, reason.to_s.truncate(300)
      end
      result["result"].to_s
    end

    # 組み込みツール（Web検索など）の呼び出しと結果を、MCP のツールと同じ形の記録にする
    def builtin_events(messages)
      calls = {}
      results = {}
      messages.each do |m|
        # message が文字列の行（システムの通知など）もある
        content = m["message"].is_a?(Hash) ? m["message"]["content"] : nil
        Array(content).each do |c|
          next unless c.is_a?(Hash)

          # mcp__ はキャラクターのツール（MCP サーバが記録する）、StructuredOutput は json_schema の答え
          if m["type"] == "assistant" && c["type"] == "tool_use" && !c["name"].to_s.start_with?("mcp__") &&
              c["name"] != ProgressRelay::STRUCTURED_OUTPUT_TOOL
            calls[c["id"]] = c
          elsif m["type"] == "user" && c["type"] == "tool_result"
            results[c["tool_use_id"]] = tool_result_text(c["content"])
          end
        end
      end

      calls.map do |id, call|
        name = BUILTIN_EVENT_NAMES.fetch(call["name"], call["name"])
        args = (call["input"] || {}).slice(*BUILTIN_EVENT_ARGS)
        result = { answer: results[id].to_s.truncate(BUILTIN_RESULT_CHARS) }
        # 何をしたか（検索語・開いた URL・実行したコマンドなど）を会話ログに残す
        result[:log] = ["[#{call["name"]}] #{args.values.join(" ").truncate(300)}"]
        { name: name, args: args, result: result }
      end
    end

    def tool_result_text(content)
      return content.to_s unless content.is_a?(Array)

      content.filter_map { |c| c["text"] if c.is_a?(Hash) }.join("\n")
    end

    def read_events(path)
      return [] unless File.exist?(path)

      File.readlines(path, encoding: "utf-8").filter_map do |line|
        event = JSON.parse(line)
        {
          name: event["name"].to_s,
          args: event["args"] || {},
          result: event["result"].is_a?(Hash) ? event["result"].deep_symbolize_keys : { response: event["result"] },
        }
      rescue JSON::ParserError
        nil
      end
    end
  end
end
