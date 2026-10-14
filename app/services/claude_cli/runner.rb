require "open3"
require "tmpdir"

module ClaudeCli
  # claude -p を1回実行する。
  #
  # ツールは MCP サーバ（bin/memoria_mcp）として渡す。MCP サーバは実行したツールの記録を
  # 一時ファイル（JSON Lines）に書き、ここで読み戻して返す。Claude Code の組み込みツール
  # （Bash・Edit など）、設定ファイル、CLAUDE.md は使わない。
  class Runner
    Result = Struct.new(:text, :tool_events, :model, keyword_init: true)

    DEFAULT_TIMEOUT = 600
    DEFAULT_MAX_TURNS = 20

    def initialize(command: ENV.fetch("CLAUDE_CLI_COMMAND", "claude"),
                   timeout: ENV.fetch("CLAUDE_CLI_TIMEOUT", DEFAULT_TIMEOUT).to_i,
                   max_turns: ENV.fetch("CLAUDE_CLI_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
                   mcp_command: Rails.root.join("bin/memoria_mcp").to_s)
      @command = command
      @timeout = timeout
      @max_turns = max_turns
      @mcp_command = mcp_command
    end

    # @param scene [Symbol] :chat / :thinking（MCP サーバが出すツールが変わる）
    # @param trigger_type [String] ツール内の Gemini 呼び出しを ApiUsageLog に記録するときの区分
    # @return [Result] text: 最終応答、tool_events: [{ name:, args:, result: }]
    def run(system_prompt:, prompt:, character:, scene:, model:, trigger_type:, platform: nil)
      Dir.mktmpdir("memoria-claude") do |dir|
        events_path = File.join(dir, "tool_events.jsonl")
        config_path = File.join(dir, "mcp.json")
        work_dir = File.join(dir, "work")
        Dir.mkdir(work_dir)

        File.write(config_path, JSON.generate(mcp_config(character, scene, platform, trigger_type, events_path)))

        stdout, stderr, status = execute(command_line(system_prompt, model, config_path), prompt, work_dir)
        text = parse_output(stdout, stderr, status)

        Result.new(text: text, tool_events: read_events(events_path), model: model)
      end
    end

    private

    def mcp_config(character, scene, platform, trigger_type, events_path)
      args = ["--character", character.id.to_s, "--scene", scene.to_s, "--trigger", trigger_type]
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
      [
        @command, "-p",
        "--output-format", "json",
        "--model", model,
        "--system-prompt", system_prompt,
        "--tools", "",
        "--strict-mcp-config", "--mcp-config", config_path,
        "--allowedTools", "mcp__memoria",
        "--setting-sources", "",
        "--no-session-persistence",
        "--max-turns", @max_turns.to_s
      ]
    end

    # プロンプトは長くなるので標準入力で渡す。時間切れのときはプロセスグループごと止める
    # （claude が起動した MCP サーバも残さない）
    def execute(cmd, prompt, work_dir)
      Open3.popen3(*cmd, chdir: work_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        out_reader = Thread.new { stdout.read }
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

    def parse_output(stdout, stderr, status)
      result = JSON.parse(stdout.to_s.lines.reverse.find { |l| l.strip.start_with?("{") } || "")
      if result["is_error"] || result["subtype"] != "success"
        reason = result["result"].presence || result["subtype"] || "不明なエラー"
        raise Error, reason.to_s.truncate(300)
      end
      result["result"].to_s
    rescue JSON::ParserError
      detail = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "出力なし"
      raise Error, "終了コード #{status&.exitstatus}: #{detail.truncate(300)}"
    end

    def read_events(path)
      return [] unless File.exist?(path)

      File.readlines(path).filter_map do |line|
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
