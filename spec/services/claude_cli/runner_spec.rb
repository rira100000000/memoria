require "rails_helper"

RSpec.describe ClaudeCli::Runner do
  let(:character) { create(:character) }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  # claude の代わりに動くスクリプト。引数とプロンプトを記録し、MCP の設定から記録ファイルの場所を読んで書き込む
  def fake_claude(body)
    path = File.join(dir, "fake_claude")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # encoding: utf-8
      require "json"
      $stdin.set_encoding("UTF-8")
      $stdout.set_encoding("UTF-8")
      args = ARGV.dup
      prompt = $stdin.read
      File.write(#{File.join(dir, "args.json").inspect}, JSON.generate(args: args, prompt: prompt, cwd: Dir.pwd))
      config = args.include?("--mcp-config") ? JSON.parse(File.read(args[args.index("--mcp-config") + 1])) : {}
      events = config.dig("mcpServers", "memoria", "env", "MEMORIA_MCP_EVENTS")
      #{body}
    RUBY
    File.chmod(0o755, path)
    path
  end

  def run_with(body, **opts)
    described_class.new(command: fake_claude(body), **opts)
      .run(system_prompt: "SYS", prompt: "こんにちは", character: character, scene: :chat, platform: :discord,
           model: "sonnet", trigger_type: "user_message")
  end

  def recorded
    JSON.parse(File.read(File.join(dir, "args.json")))
  end

  it "returns the final text and the tool events" do
    result = run_with(<<~RUBY)
      File.write(events, JSON.generate(name: "semantic_search", args: { query: "猫" }, result: { results: "記憶", log: ["x"] }) + "\\n")
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "やあ")
    RUBY

    expect(result.text).to eq("やあ")
    expect(result.model).to eq("sonnet")
    expect(result.tool_events).to eq([{ name: "semantic_search", args: { "query" => "猫" }, result: { results: "記憶", log: ["x"] } }])
  end

  it "passes the prompt on stdin and runs claude with only read-only built-in tools and no settings" do
    run_with('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")')

    args = recorded["args"]
    expect(recorded["prompt"]).to eq("こんにちは")
    expect(args).to include("-p", "--strict-mcp-config", "--no-session-persistence")
    expect(args[args.index("--tools") + 1]).to eq("WebSearch,WebFetch")
    expect(args[args.index("--setting-sources") + 1]).to eq("")
    expect(args[args.index("--model") + 1]).to eq("sonnet")
    expect(args[args.index("--system-prompt") + 1]).to eq("SYS")
    expect(args[args.index("--allowedTools") + 1, 3]).to eq(%w[mcp__memoria WebSearch WebFetch])
    expect(recorded["cwd"]).to end_with("/work")
  end

  it "starts the MCP server for the character, scene and platform" do
    path = fake_claude(<<~RUBY)
      File.write(#{File.join(dir, "config.json").inspect}, JSON.generate(config))
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")
    RUBY
    described_class.new(command: path)
      .run(system_prompt: "S", prompt: "P", character: character, scene: :thinking, model: "sonnet", trigger_type: "thinking_loop")

    server = JSON.parse(File.read(File.join(dir, "config.json"))).dig("mcpServers", "memoria")
    expect(server["command"]).to eq(Rails.root.join("bin/memoria_mcp").to_s)
    expect(server["args"]).to eq(["--character", character.id.to_s, "--scene", "thinking", "--trigger", "thinking_loop"])
    expect(server["env"]).not_to have_key("MEMORIA_MCP_CONTEXT")
  end

  it "passes the usage context to the MCP server" do
    path = fake_claude(<<~RUBY)
      File.write(#{File.join(dir, "config.json").inspect}, JSON.generate(config))
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")
    RUBY
    described_class.new(command: path)
      .run(system_prompt: "S", prompt: "P", character: character, scene: :thinking, model: "sonnet", trigger_type: "thinking_loop",
           usage_context: { wakeup_id: 7, purpose: "朝の見回り" })

    env = JSON.parse(File.read(File.join(dir, "config.json"))).dig("mcpServers", "memoria", "env")
    expect(JSON.parse(env["MEMORIA_MCP_CONTEXT"])).to eq("wakeup_id" => 7, "purpose" => "朝の見回り")
  end

  it "records built-in web searches as tool events" do
    result = run_with(<<~RUBY)
      puts JSON.generate(type: "system", subtype: "init")
      puts JSON.generate(type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "WebSearch", input: { query: "天気", mode: "standard" } }] })
      puts JSON.generate(type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "晴れ" }] }] })
      puts JSON.generate(type: "assistant", message: { content: [{ type: "text", text: "晴れだよ" }] })
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "晴れだよ")
    RUBY

    expect(result.text).to eq("晴れだよ")
    expect(result.tool_events).to eq([{ name: "web_search", args: { "query" => "天気" }, result: { answer: "晴れ", log: ["[WebSearch] 天気"] } }])
  end

  it "passes text written before a tool use as progress, but not the final answer or subagent text" do
    progress = []
    result = described_class.new(command: fake_claude(<<~RUBY))
      puts JSON.generate(type: "assistant", message: { id: "m1", content: [{ type: "text", text: "調べてみるね" }] })
      puts JSON.generate(type: "assistant", message: { id: "m1", content: [{ type: "tool_use", id: "t1", name: "Agent", input: {} }] })
      puts JSON.generate(type: "assistant", parent_tool_use_id: "t1", message: { id: "m2", content: [{ type: "text", text: "サブの文" }] })
      puts JSON.generate(type: "assistant", parent_tool_use_id: "t1", message: { id: "m2", content: [{ type: "tool_use", id: "t2", name: "WebSearch", input: {} }] })
      puts JSON.generate(type: "assistant", message: { id: "m3", content: [{ type: "text", text: "分かったよ" }] })
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "分かったよ")
    RUBY
      .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet",
           on_progress: ->(text) { progress << text })

    expect(progress).to eq(["調べてみるね"])
    expect(result.text).to eq("分かったよ")
  end

  it "asks for an answer in the given shape and returns it, without passing the text before it as progress" do
    progress = []
    result = described_class.new(command: fake_claude(<<~RUBY))
      puts JSON.generate(type: "assistant", message: { id: "m1", content: [{ type: "text", text: "まとめるね" }] })
      puts JSON.generate(type: "assistant", message: { id: "m1", content: [{ type: "tool_use", id: "t1", name: "StructuredOutput", input: { reply: "やあ" } }] })
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: '{"reply":"やあ"}', structured_output: { reply: "やあ" })
    RUBY
      .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet",
           json_schema: { type: "object" }, on_progress: ->(text) { progress << text })

    args = recorded["args"]
    expect(args[args.index("--json-schema") + 1]).to eq('{"type":"object"}')
    expect(result.structured).to eq("reply" => "やあ")
    expect(result.tool_events).to be_empty  # 答えのツールは、ツールを使った記録に残さない
    expect(progress).to be_empty
  end

  it "can use all Claude Code tools in a given directory with a settings file" do
    work = File.join(dir, "vault")
    Dir.mkdir(work)
    described_class.new(command: fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")'),
      builtin_tools: "default", work_dir: work, settings: "/path/to/settings.json")
      .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet")

    args = recorded["args"]
    expect(recorded["cwd"]).to eq(work)
    expect(args[args.index("--tools") + 1]).to eq("default")
    expect(args[args.index("--allowedTools") + 1..]).to start_with("mcp__memoria").and(include("--settings"))
    expect(args[args.index("--allowedTools") + 2]).to eq("--settings")
    expect(args[args.index("--settings") + 1]).to eq("/path/to/settings.json")
  end

  it "gives each character its own built-in tools when set" do
    claude = fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")')
    runner = described_class.new(command: claude, builtin_tools: "default",
      builtin_tools_by_character: "#{character.vault_dir_name}=WebSearch,WebFetch; other=")

    runner.run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet")

    args = recorded["args"]
    expect(args[args.index("--tools") + 1]).to eq("WebSearch,WebFetch")
    expect(args[args.index("--allowedTools") + 1..]).to eq(%w[mcp__memoria WebSearch WebFetch])
  end

  it "uses no built-in tools for a character set to none" do
    claude = fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")')
    described_class.new(command: claude, builtin_tools: "default", builtin_tools_by_character: "#{character.vault_dir_name}=")
      .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet")

    args = recorded["args"]
    expect(args[args.index("--tools") + 1]).to eq("")
  end

  it "keeps light work out of the given directory" do
    work = File.join(dir, "vault")
    Dir.mkdir(work)
    described_class.new(command: fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")'),
      work_dir: work, settings: "/path/to/settings.json")
      .run(system_prompt: "S", prompt: "P", model: "haiku")

    expect(recorded["cwd"]).not_to eq(work)
    expect(recorded["args"]).not_to include("--settings")
  end

  it "records other built-in tool uses with a log line" do
    result = run_with(<<~RUBY)
      puts JSON.generate(type: "system", subtype: "notice", message: "文字列のメッセージ")
      puts JSON.generate(type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "ls", description: "一覧" } }] })
      puts JSON.generate(type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "a.md" }] })
      puts JSON.generate(type: "assistant", message: { content: [{ type: "tool_use", id: "t2", name: "mcp__memoria__semantic_search", input: { query: "x" } }] })
      puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")
    RUBY

    expect(result.tool_events).to eq([{ name: "Bash", args: { "command" => "ls", "description" => "一覧" },
                                        result: { answer: "a.md", log: ["[Bash] ls 一覧"] } }])
  end

  it "runs without tools when no character is given" do
    result = described_class.new(command: fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "要約")'))
      .run(system_prompt: "S", prompt: "P", model: "haiku")

    expect(result.text).to eq("要約")
    expect(result.tool_events).to eq([])
    expect(recorded["args"]).not_to include("--mcp-config", "--allowedTools")
    expect(recorded["args"][recorded["args"].index("--tools") + 1]).to eq("")
    expect(recorded["args"][recorded["args"].index("--model") + 1]).to eq("haiku")
  end

  it "raises when claude reports an error (e.g. the usage limit)" do
    expect {
      run_with('puts JSON.generate(type: "result", subtype: "success", is_error: true, result: "usage limit reached")')
    }.to raise_error(ClaudeCli::Error, /usage limit/)
  end

  it "raises when claude stops without success (e.g. too many turns)" do
    expect {
      run_with('puts JSON.generate(type: "result", subtype: "error_max_turns", is_error: false)')
    }.to raise_error(ClaudeCli::Error, /error_max_turns/)
  end

  it "raises with stderr when the output is not JSON" do
    expect {
      run_with('warn "not logged in"; exit 1')
    }.to raise_error(ClaudeCli::Error, /終了コード 1: not logged in/)
  end

  describe "stopping" do
    let(:result_line) { 'puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")' }

    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    it "stops when there is no output for the idle timeout" do
      time = elapsed do
        expect {
          run_with("sleep 10", idle_timeout: 1, timeout: 60, poll_interval: 0.1)
        }.to raise_error(ClaudeCli::Error, /1秒出力がなかったので止めました/)
      end
      expect(time).to be < 5
    end

    it "keeps running while the output goes on, even past the idle timeout" do
      result = run_with(<<~RUBY, idle_timeout: 1, timeout: 60, poll_interval: 0.1)
        $stdout.sync = true
        6.times { puts JSON.generate(type: "system", subtype: "progress"); sleep 0.4 }
        #{result_line}
      RUBY

      expect(result.text).to eq("ok")
    end

    it "stops at the overall limit even while the output goes on" do
      expect {
        run_with(<<~RUBY, idle_timeout: 60, timeout: 1, poll_interval: 0.1)
          $stdout.sync = true
          50.times { puts JSON.generate(type: "system", subtype: "progress"); sleep 0.2 }
        RUBY
      }.to raise_error(ClaudeCli::Error, /1秒たっても終わらなかったので止めました/)
    end

    it "stops the processes the command started" do
      pid_path = File.join(dir, "child.pid")
      expect {
        run_with(<<~RUBY, idle_timeout: 1, timeout: 60, poll_interval: 0.1)
          pid = spawn("sleep", "30")
          File.write(#{pid_path.inspect}, pid.to_s)
          Process.wait(pid)
        RUBY
      }.to raise_error(ClaudeCli::Error)

      pid = File.read(pid_path).to_i
      gone = 20.times.any? do
        Process.kill(0, pid)
        sleep 0.1
        false
      rescue Errno::ESRCH
        true
      end
      expect(gone).to be(true)
    end

    it "passes where to declare a long think to the MCP server, in this run's own directory" do
      run_with(<<~RUBY)
        File.write(#{File.join(dir, "long_think_path").inspect}, config.dig("mcpServers", "memoria", "env", "MEMORIA_MCP_LONG_THINK"))
        #{result_line}
      RUBY

      path = File.read(File.join(dir, "long_think_path"))
      expect(File.dirname(path)).to eq(File.dirname(recorded["cwd"]))
      expect(File.exist?(File.dirname(path))).to be(false) # 終わったら片づける
    end

    # MCP サーバの long_think ツールの代わりに、宣言のファイルを書く
    def declare_long_think(minutes:, seconds:, reason:)
      <<~RUBY
        path = config.dig("mcpServers", "memoria", "env", "MEMORIA_MCP_LONG_THINK")
        File.write(path, JSON.generate(until: Time.now.to_f + #{seconds}, minutes: #{minutes}, reason: #{reason.inspect}))
      RUBY
    end

    it "does not stop without output while a long think is declared, and tells it as progress" do
      progress = []
      claude = fake_claude(<<~RUBY)
        #{declare_long_think(minutes: 5, seconds: 300, reason: "ベンチマーク")}
        sleep 2.5
        #{result_line}
      RUBY
      result = described_class.new(command: claude, idle_timeout: 1, timeout: 60, poll_interval: 0.1)
        .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet",
             on_progress: ->(text) { progress << text })

      expect(result.text).to eq("ok")
      expect(progress).to eq(["長考中（〜5分：ベンチマーク）"])
    end

    it "goes back to the idle timeout after the long think ends" do
      expect {
        run_with(<<~RUBY, idle_timeout: 1, timeout: 60, poll_interval: 0.1)
          #{declare_long_think(minutes: 1, seconds: 1, reason: "短い")}
          sleep 10
        RUBY
      }.to raise_error(ClaudeCli::Error, /出力がなかったので止めました/)
    end
  end

  it "raises when the command is missing" do
    runner = described_class.new(command: File.join(dir, "no_such_claude"))
    expect {
      runner.run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet", trigger_type: "user_message")
    }.to raise_error(ClaudeCli::Error, /見つかりません/)
  end
end
