require "open3"
require "tmpdir"

module ClaudeCli
  # claude -p（または codex exec）を1回実行する。どちらで動かすかは LLM_CLI_BACKEND で決める
  # （claude / codex。未設定なら claude）。コマンドの組み立てと出力の読み方は Backends::Claude / Backends::Codex にある。
  #
  # キャラクターを指定したときは、そのツールを MCP サーバ（bin/memoria_mcp）として渡す。
  # MCP サーバは実行したツールの記録を一時ファイル（JSON Lines）に書き、ここで読み戻して返す。
  # 組み込みツールは、既定では読むだけのもの（WebSearch・WebFetch）をキャラクターのツールと
  # 一緒に使わせる。CLAUDE_CLI_BUILTIN_TOOLS=default にすると全部使わせる（claude の権限は CLAUDE_CLI_SETTINGS の
  # 設定ファイルで、codex はサンドボックス CODEX_CLI_SANDBOX で決める）。キャラクターごとに変えるときは
  # CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER に "vault_dir_name=ツール,ツール;vault_dir_name=default" の形で書く
  # （"vault_dir_name=" なら使わせない）。
  # 作業ディレクトリは CLAUDE_CLI_WORKDIR（未設定なら空の一時ディレクトリ）。
  # 出力が CLAUDE_CLI_IDLE_TIMEOUT 秒とぎれたら止める。キャラクターが long_think ツールで長考を宣言したら、
  # その期限までは出力がなくても止めない。答えのあと裏の作業（run_in_background）が終わるのを待っている間も止めない。
  # 経過時間の上限 CLAUDE_CLI_TIMEOUT は安全弁として残す（答えが出ていれば、止めても答えは返す）。
  # 利用者の Claude Code / Codex の設定ファイルは読まない。
  class Runner
    Result = Struct.new(:text, :tool_events, :model, :structured, :followups, keyword_init: true)

    # 経過時間の上限（安全弁）
    DEFAULT_TIMEOUT = 7200
    # 出力がこれだけとぎれたら止める
    DEFAULT_IDLE_TIMEOUT = 600
    # 止まっていないかを見る間隔
    POLL_INTERVAL = 1
    DEFAULT_MAX_TURNS = 20
    # キャラクターのツールと一緒に使わせる組み込みツール（読むだけのもの）
    DEFAULT_BUILTIN_TOOLS = "WebSearch,WebFetch"

    attr_reader :backend

    # @param backend [String, Symbol, #command_line] "claude" / "codex"、またはバックエンドそのもの
    # @param command [String, nil] 実行するコマンド（未設定なら CLAUDE_CLI_COMMAND / CODEX_CLI_COMMAND）
    def initialize(backend: ClaudeCli.backend,
                   command: nil,
                   timeout: ENV.fetch("CLAUDE_CLI_TIMEOUT", DEFAULT_TIMEOUT).to_i,
                   idle_timeout: ENV.fetch("CLAUDE_CLI_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT).to_i,
                   poll_interval: POLL_INTERVAL,
                   max_turns: ENV.fetch("CLAUDE_CLI_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
                   builtin_tools: ENV.fetch("CLAUDE_CLI_BUILTIN_TOOLS", DEFAULT_BUILTIN_TOOLS),
                   builtin_tools_by_character: ENV["CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER"],
                   work_dir: ENV["CLAUDE_CLI_WORKDIR"].presence,
                   settings: ENV["CLAUDE_CLI_SETTINGS"].presence,
                   codex_home: ENV["CODEX_CLI_HOME"].presence,
                   codex_sandbox: ENV["CODEX_CLI_SANDBOX"].presence,
                   mcp_command: Rails.root.join("bin/memoria_mcp").to_s)
      @backend =
        case backend.to_s
        when "codex"
          Backends::Codex.new(command: command || ENV.fetch("CODEX_CLI_COMMAND", "codex"), home: codex_home,
                              sandbox: codex_sandbox, tool_timeout: idle_timeout)
        when "claude", ""
          Backends::Claude.new(command: command || ENV.fetch("CLAUDE_CLI_COMMAND", "claude"), max_turns: max_turns, settings: settings)
        else
          raise ArgumentError, "unknown backend: #{backend}" unless backend.respond_to?(:command_line)

          backend
        end
      @work_dir = work_dir
      @builtin_tools = tool_list(builtin_tools)
      @builtin_tools_by_character = builtin_tools_by_character.to_s.split(";").filter_map { |entry|
        key, tools = entry.split("=", 2)
        [key.strip, tool_list(tools)] if key.to_s.strip.present? && tools
      }.to_h
      @timeout = timeout
      @idle_timeout = idle_timeout
      @poll_interval = poll_interval
      @mcp_command = mcp_command
    end

    # @param character [Character, nil] 指定するとそのキャラクターのツールを MCP で渡す。nil ならツールなし
    # @param scene [Symbol] :chat / :thinking（MCP サーバが出すツールが変わる）
    # @param trigger_type [String] ツール内の Gemini 呼び出し（埋め込みなど）を ApiUsageLog に記録するときの区分
    # @param on_progress [#call, nil] ツールを使う前に書いた文（「調べてみるね」など）を、終わるのを待たずに受け取る
    # @param json_schema [Hash, nil] 指定すると、この形で答えさせる（Result#structured に入る）
    # @param usage_context [Hash, nil] ツールの使用記録（ToolUsageLog）に添える場面の情報（予定の { wakeup_id:, purpose: }）
    # @return [Result] text: 最終応答、tool_events: [{ name:, args:, result: }]、structured: json_schema の形の答え、
    #   followups: 答えのあと、裏の作業が終わった知らせで動いて出した答え（[{ text:, structured: }]）
    def run(system_prompt:, prompt:, model:, character: nil, scene: nil, trigger_type: nil, platform: nil, on_progress: nil, json_schema: nil, usage_context: nil)
      Dir.mktmpdir("memoria-claude") do |dir|
        events_path = File.join(dir, "tool_events.jsonl")
        long_think = LongThink.new(File.join(dir, "long_think.json"))
        work_dir = File.join(dir, "work")
        Dir.mkdir(work_dir)

        config = character && mcp_config(character, scene, platform, trigger_type, events_path, long_think, usage_context)

        # キャラクターとして動くときだけ、指定された作業ディレクトリで動かす（軽い作業は空のディレクトリ）
        work_dir = @work_dir if character && @work_dir
        relay = on_progress && @backend.progress_relay(on_progress)
        background = @backend.respond_to?(:background_tracker) ? @backend.background_tracker : nil
        builtin = character ? @builtin_tools_by_character.fetch(character.vault_dir_name, @builtin_tools) : []
        cmd = @backend.command_line(dir: dir, system_prompt: system_prompt, model: model, mcp_config: config,
                                    builtin: builtin, json_schema: json_schema)
        stdout, stderr, status = execute(cmd, prompt, work_dir, relay, long_think: character && long_think, background: background)
        parsed = @backend.parse(stdout, stderr, status, json_schema: json_schema)

        Result.new(text: parsed[:text], tool_events: read_events(events_path) + parsed[:builtin_events], model: model,
                   structured: parsed[:structured], followups: parsed[:followups] || [])
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

    # プロンプトは長くなるので標準入力で渡す。出力がとぎれたとき（長考の宣言中を除く）と、経過時間の上限を
    # 超えたときは、プロセスグループごと止める（コマンドが起動した MCP サーバも残さない）
    def execute(cmd, prompt, work_dir, relay = nil, long_think: nil, background: nil)
      # Brakeman は第1引数がハッシュのリテラルでないとコマンド文字列とみなすので、環境変数はリテラルに展開して渡す
      Open3.popen3({ **@backend.env }, *cmd, chdir: work_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
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
              background&.feed(line)
            end
            out
          end
          readers << Thread.new { stderr.read }
          stdin.write(prompt)
          stdin.close

          # 答えのあとに経過時間の上限が来たら、残った作業を止めて、そこまでの出力（答え）を読む
          kill_group(wait_thr) if watch(wait_thr, activity, relay, long_think, background) == :answered_timeout
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
      raise Error, "#{@backend.command} コマンドが見つかりません"
    end

    # 終わるまで見張る。止めるべきときは Error を上げる（プロセスは execute の ensure で止める）。
    # 答えが出たあとに止めることになったときは :answered_timeout を返す
    def watch(wait_thr, activity, relay, long_think, background = nil)
      started = monotonic_now
      announced = nil
      announced_tasks = nil
      until wait_thr.join(@poll_interval)
        declaration = long_think&.read
        if declaration && declaration != announced
          announced = declaration
          relay&.notify("長考中（〜#{declaration.minutes}分：#{declaration.reason}）")
        end

        waiting = background&.waiting_tasks || []
        if waiting.any? && waiting != announced_tasks
          announced_tasks = waiting
          relay&.notify("裏の作業が終わるのを待ってる（#{waiting.join("、")}）")
        end

        if monotonic_now - started > @timeout
          return :answered_timeout if background&.answered?

          raise Error, "#{duration_text(@timeout)}たっても終わらなかったので止めました"
        end
        next if declaration && Time.now < declaration.until_time
        next if waiting.any?

        idle = activity.idle_seconds
        # 長考の期限が過ぎたばかりなら、そこから数え直す（期限の直後に止めない）
        idle = [idle, Time.now - declaration.until_time].min if declaration
        next unless idle > @idle_timeout
        return :answered_timeout if background&.answered?

        raise Error, "#{duration_text(@idle_timeout)}出力がなかったので止めました"
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
