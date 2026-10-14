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
      require "json"
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

  it "passes the prompt on stdin and runs claude without built-in tools or settings" do
    run_with('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "ok")')

    args = recorded["args"]
    expect(recorded["prompt"]).to eq("こんにちは")
    expect(args).to include("-p", "--strict-mcp-config", "--no-session-persistence")
    expect(args[args.index("--tools") + 1]).to eq("")
    expect(args[args.index("--setting-sources") + 1]).to eq("")
    expect(args[args.index("--model") + 1]).to eq("sonnet")
    expect(args[args.index("--system-prompt") + 1]).to eq("SYS")
    expect(args[args.index("--allowedTools") + 1]).to eq("mcp__memoria")
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
  end

  it "runs without tools when no character is given" do
    result = described_class.new(command: fake_claude('puts JSON.generate(type: "result", subtype: "success", is_error: false, result: "要約")'))
      .run(system_prompt: "S", prompt: "P", model: "haiku")

    expect(result.text).to eq("要約")
    expect(result.tool_events).to eq([])
    expect(recorded["args"]).not_to include("--mcp-config", "--allowedTools")
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

  it "raises on timeout" do
    expect {
      run_with("sleep 5", timeout: 1)
    }.to raise_error(ClaudeCli::Error, /1秒/)
  end

  it "raises when the command is missing" do
    runner = described_class.new(command: File.join(dir, "no_such_claude"))
    expect {
      runner.run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "sonnet", trigger_type: "user_message")
    }.to raise_error(ClaudeCli::Error, /見つかりません/)
  end
end
