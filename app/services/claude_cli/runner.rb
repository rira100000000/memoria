require "open3"
require "tmpdir"

module ClaudeCli
  # claude -p を1回実行する。
  #
  # キャラクターを指定したときは、そのツールを MCP サーバ（bin/memoria_mcp）として渡す。
  # MCP サーバは実行したツールの記録を一時ファイル（JSON Lines）に書き、ここで読み戻して返す。
  # Claude Code の組み込みツールは、既定では読むだけのもの（WebSearch・WebFetch）をキャラクターのツールと
  # 一緒に使わせる。CLAUDE_CLI_BUILTIN_TOOLS=default にすると全部使わせる（権限は CLAUDE_CLI_SETTINGS の
  # 設定ファイルで決める）。作業ディレクトリは CLAUDE_CLI_WORKDIR（未設定なら空の一時ディレクトリ）。
  # 利用者の Claude Code の設定ファイル（~/.claude など）は読まない。
  class Runner
    Result = Struct.new(:text, :tool_events, :model, keyword_init: true)

    DEFAULT_TIMEOUT = 600
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
                   max_turns: ENV.fetch("CLAUDE_CLI_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
                   builtin_tools: ENV.fetch("CLAUDE_CLI_BUILTIN_TOOLS", DEFAULT_BUILTIN_TOOLS),
                   work_dir: ENV["CLAUDE_CLI_WORKDIR"].presence,
                   settings: ENV["CLAUDE_CLI_SETTINGS"].presence,
                   mcp_command: Rails.root.join("bin/memoria_mcp").to_s)
      @command = command
      @work_dir = work_dir
      @settings = settings
      @builtin_tools = builtin_tools.to_s.split(",").map(&:strip).reject(&:empty?)
      @timeout = timeout
      @max_turns = max_turns
      @mcp_command = mcp_command
    end

    # @param character [Character, nil] 指定するとそのキャラクターのツールを MCP で渡す。nil ならツールなし
    # @param scene [Symbol] :chat / :thinking（MCP サーバが出すツールが変わる）
    # @param trigger_type [String] ツール内の Gemini 呼び出し（埋め込みなど）を ApiUsageLog に記録するときの区分
    # @param on_progress [#call, nil] ツールを使う前に書いた文（「調べてみるね」など）を、終わるのを待たずに受け取る
    # @return [Result] text: 最終応答、tool_events: [{ name:, args:, result: }]
    def run(system_prompt:, prompt:, model:, character: nil, scene: nil, trigger_type: nil, platform: nil, on_progress: nil)
      Dir.mktmpdir("memoria-claude") do |dir|
        events_path = File.join(dir, "tool_events.jsonl")
        work_dir = File.join(dir, "work")
        Dir.mkdir(work_dir)

        config_path = nil
        if character
          config_path = File.join(dir, "mcp.json")
          File.write(config_path, JSON.generate(mcp_config(character, scene, platform, trigger_type, events_path)))
        end

        # キャラクターとして動くときだけ、指定された作業ディレクトリで動かす（軽い作業は空のディレクトリ）
        work_dir = @work_dir if character && @work_dir
        relay = on_progress && ProgressRelay.new(on_progress)
        stdout, stderr, status = execute(command_line(system_prompt, model, config_path), prompt, work_dir, relay)
        messages = parse_stream(stdout)
        text = final_text(messages, stdout, stderr, status)

        Result.new(text: text, tool_events: read_events(events_path) + builtin_events(messages), model: model)
      end
    end

    private

    def mcp_config(character, scene, platform, trigger_type, events_path)
      args = ["--character", character.id.to_s, "--scene", scene.to_s]
      args += ["--trigger", trigger_type] if trigger_type
      args += ["--platform", platform.to_s] if platform
      {
        mcpServers: {
          memoria: {
            command: @mcp_command,
            args: args,
            env: { "MEMORIA_MCP_EVENTS" => events_path, "RAILS_ENV" => Rails.env.to_s },
          },
        },
      }
    end

    def command_line(system_prompt, model, config_path)
      builtin = config_path ? @builtin_tools : []
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
      if config_path
        # "default"（全部）のときの許可は設定ファイルの権限に任せ、個別に名前を挙げたものだけ許可に足す
        allowed = builtin == ["default"] ? [] : builtin
        cmd += ["--mcp-config", config_path, "--allowedTools", "mcp__memoria", *allowed]
        cmd += ["--settings", @settings] if @settings
      end
      cmd
    end

    # プロンプトは長くなるので標準入力で渡す。時間切れのときはプロセスグループごと止める
    # （claude が起動した MCP サーバも残さない）
    def execute(cmd, prompt, work_dir, relay = nil)
      Open3.popen3(*cmd, chdir: work_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        # ロケールに関係なく UTF-8 として読み書きする（LANG のない環境では ASCII として扱われ、日本語で壊れる）
        [stdin, stdout, stderr].each { |io| io.set_encoding(Encoding::UTF_8) }
        out_reader = Thread.new do
          out = +""
          stdout.each_line do |line|
            out << line
            relay&.feed(line)
          end
          out
        end
        err_reader = Thread.new { stderr.read }
        stdin.write(prompt)
        stdin.close

        unless wait_thr.join(@timeout)
          kill_group(wait_thr.pid)
          raise Error, "#{@timeout}秒たっても終わらなかったので止めました"
        end

        [out_reader.value, err_reader.value, wait_thr.value]
      end
    rescue Errno::ENOENT
      raise Error, "#{@command} コマンドが見つかりません"
    end

    def kill_group(pid)
      Process.kill("TERM", -pid)
      sleep 2
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    # stream-json を1行ずつ受け取り、ツールを使う前に書いた文を途中経過として渡す。
    # 最終応答は result の行から取るので、ここでは渡さない（ツールを使う前の文だけが途中経過になる）。
    # サブエージェントの文（parent_tool_use_id があるもの）も渡さない
    class ProgressRelay
      def initialize(callback)
        @callback = callback
        @pending = []
      end

      def feed(line)
        return unless line.strip.start_with?("{")

        m = JSON.parse(line)
        return unless m["type"] == "assistant" && m["message"].is_a?(Hash) && m["parent_tool_use_id"].nil?

        Array(m["message"]["content"]).each do |c|
          next unless c.is_a?(Hash)

          if c["type"] == "text" && c["text"].to_s.strip.present?
            @pending << c["text"].strip
          elsif c["type"] == "tool_use"
            flush
          end
        end
      rescue JSON::ParserError
        nil
      end

      private

      def flush
        texts = @pending
        @pending = []
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

          if m["type"] == "assistant" && c["type"] == "tool_use" && !c["name"].to_s.start_with?("mcp__")
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
