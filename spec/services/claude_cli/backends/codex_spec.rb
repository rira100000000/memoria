require "rails_helper"

RSpec.describe ClaudeCli::Backends::Codex do
  let(:character) { create(:character) }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def fixture(name)
    Rails.root.join("spec/fixtures/files/codex/#{name}.jsonl").to_s
  end

  # codex の代わりに動くスクリプト。引数・プロンプト・環境変数と、渡されたファイルの中身を記録し、
  # MCP の設定（-c mcp_servers.memoria.env）から記録ファイルの場所を読んで書き込む
  def fake_codex(body)
    path = File.join(dir, "fake_codex")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # encoding: utf-8
      require "json"
      $stdin.set_encoding("UTF-8")
      $stdout.set_encoding("UTF-8")
      args = ARGV.dup
      prompt = $stdin.read
      config = args.each_cons(2).filter_map { |flag, value| value.split("=", 2) if flag == "-c" }.to_h
      read = ->(key) { value = config[key]; value && File.exist?(JSON.parse(value)) ? File.read(JSON.parse(value)) : nil }
      schema = args.include?("--output-schema") ? File.read(args[args.index("--output-schema") + 1]) : nil
      File.write(#{File.join(dir, "args.json").inspect}, JSON.generate(args: args, prompt: prompt, cwd: Dir.pwd, config: config,
        instructions: read.call("model_instructions_file"), schema: schema,
        env: { "CODEX_HOME" => ENV["CODEX_HOME"], "PATH" => ENV["PATH"] }))
      env = config["mcp_servers.memoria.env"].to_s
      events = env[/"MEMORIA_MCP_EVENTS" = "([^"]+)"/, 1]
      #{body}
    RUBY
    File.chmod(0o755, path)
    path
  end

  def emit(name)
    "print File.read(#{fixture(name).inspect})"
  end

  def runner(body, **opts)
    ClaudeCli::Runner.new(backend: "codex", command: fake_codex(body), **opts)
  end

  def recorded
    JSON.parse(File.read(File.join(dir, "args.json")))
  end

  def option(flag)
    args = recorded["args"]
    args[args.index(flag) + 1]
  end

  def disabled_features
    recorded["args"].each_cons(2).filter_map { |flag, value| value if flag == "--disable" }
  end

  describe "the command line" do
    it "runs codex exec with JSON events, without the user's config, and the prompt on stdin" do
      runner(emit("structured")).run(system_prompt: "SYS", prompt: "こんにちは", model: "gpt-6-luna:low")

      args = recorded["args"]
      expect(args[0]).to eq("exec")
      expect(args).to include("--json", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check")
      expect(args.last).to eq("-")
      expect(recorded["prompt"]).to eq("こんにちは")
      expect(option("--model")).to eq("gpt-6-luna")
      expect(recorded["config"]["model_reasoning_effort"]).to eq('"low"')
      expect(recorded["config"]["approval_policy"]).to eq('"never"')
      expect(recorded["config"]["project_doc_max_bytes"]).to eq("0")
      expect(recorded["config"]["skills.include_instructions"]).to eq("false")
    end

    it "passes the system prompt as the model instructions file" do
      runner(emit("structured")).run(system_prompt: "あなたはテスト用のキャラクター。", prompt: "P", model: "m")

      expect(recorded["instructions"]).to eq("あなたはテスト用のキャラクター。")
      expect(recorded["config"]).not_to have_key("model_reasoning_effort")
    end

    it "runs light work read-only, without tools, web search or the MCP server" do
      runner(emit("structured")).run(system_prompt: "S", prompt: "P", model: "m")

      expect(option("--sandbox")).to eq("read-only")
      expect(recorded["config"]["web_search"]).to eq('"disabled"')
      expect(disabled_features).to include("shell_tool", "unified_exec", "image_generation")
      expect(recorded["config"].keys.grep(/\Amcp_servers/)).to be_empty
      expect(recorded["args"]).not_to include("--output-schema")
    end

    it "starts the MCP server for the character, approved without asking and with memoria's environment" do
      ENV["MEMORIA_SPEC_FORWARDED"] = "1"
      runner(emit("structured")).run(system_prompt: "SYS", prompt: "P", character: character, scene: :thinking, model: "m",
        trigger_type: "thinking_loop", usage_context: { wakeup_id: 7, purpose: "朝の見回り" })

      config = recorded["config"]
      expect(JSON.parse(config["mcp_servers.memoria.command"])).to eq(Rails.root.join("bin/memoria_mcp").to_s)
      expect(JSON.parse(config["mcp_servers.memoria.args"]))
        .to eq(["--character", character.id.to_s, "--scene", "thinking", "--trigger", "thinking_loop"])
      expect(config["mcp_servers.memoria.default_tools_approval_mode"]).to eq('"approve"')
      expect(config["mcp_servers.memoria.env"]).to include('"MEMORIA_MCP_EVENTS" = "', '"RAILS_ENV" = "test"', '"MEMORIA_MCP_LONG_THINK" = "')
      expect(config["mcp_servers.memoria.env"]).to include('"MEMORIA_MCP_CONTEXT" = "{\"wakeup_id\":7,\"purpose\":\"朝の見回り\"}"')
      forwarded = JSON.parse(config["mcp_servers.memoria.env_vars"])
      expect(forwarded).to include("MEMORIA_SPEC_FORWARDED", "PATH")
      expect(forwarded).not_to include("MEMORIA_MCP_EVENTS")
      expect(recorded["instructions"]).to start_with("SYS").and(include("mcp__memoria__"))
    ensure
      ENV.delete("MEMORIA_SPEC_FORWARDED")
    end

    it "lets the character search the web but not run commands by default" do
      runner(emit("structured")).run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m")

      expect(option("--sandbox")).to eq("read-only")
      expect(recorded["config"]["web_search"]).to eq('"live"')
      expect(disabled_features).to include("shell_tool", "unified_exec")
      expect(recorded["cwd"]).to end_with("/work")
    end

    it "gives all codex tools in the sandbox when the built-in tools are default" do
      work = File.join(dir, "vault")
      Dir.mkdir(work)
      runner(emit("structured"), builtin_tools: "default", work_dir: work, codex_sandbox: "danger-full-access")
        .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m")

      expect(option("--sandbox")).to eq("danger-full-access")
      expect(disabled_features).to be_empty
      expect(recorded["cwd"]).to eq(work)
    end

    it "turns web search off for a character set to no built-in tools" do
      runner(emit("structured"), builtin_tools_by_character: "#{character.vault_dir_name}=")
        .run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m")

      expect(recorded["config"]["web_search"]).to eq('"disabled"')
    end

    it "uses the given CODEX_HOME and puts the command's directory on PATH" do
      home = File.join(dir, "codex_home")
      runner(emit("structured"), codex_home: home).run(system_prompt: "S", prompt: "P", model: "m")

      expect(recorded["env"]["CODEX_HOME"]).to eq(home)
      # （ruby の版の管理ツールがさらに前に足すことがあるので、順番までは見ない）
      expect(recorded["env"]["PATH"].split(File::PATH_SEPARATOR)).to include(dir)
    end

    it "writes the answer shape as a strict output schema" do
      runner(emit("structured")).run(system_prompt: "S", prompt: "P", model: "m", json_schema: ChatSession::REPLY_SCHEMA)

      schema = JSON.parse(recorded["schema"])
      expect(schema["required"]).to eq(%w[reply next_action next_step])
      expect(schema["additionalProperties"]).to be(false)
      expect(schema.dig("properties", "next_step", "type")).to eq(%w[string null])
      expect(schema.dig("properties", "next_action", "type")).to eq("string")
    end
  end

  describe ".strict_schema" do
    it "requires every property, allows null for optional ones, and goes into nested objects and arrays" do
      schema = described_class.strict_schema(
        type: "object",
        properties: {
          mood: { type: "string", enum: %w[good bad] },
          items: { type: "array", items: { type: "object", properties: { name: { type: "string" } } } },
        },
        required: %w[items]
      )

      expect(schema).to eq(
        "type" => "object",
        "properties" => {
          "mood" => { "type" => %w[string null], "enum" => ["good", "bad", nil] },
          "items" => {
            "type" => "array",
            "items" => { "type" => "object", "properties" => { "name" => { "type" => %w[string null] } },
                         "required" => ["name"], "additionalProperties" => false },
          },
        },
        "required" => %w[mood items],
        "additionalProperties" => false
      )
    end
  end

  describe "reading the output" do
    it "returns the last message, the MCP tool records and the built-in tool uses" do
      result = runner(<<~RUBY).run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m")
        File.write(events, JSON.generate(name: "semantic_search", args: { query: "猫" }, result: { results: "記憶", log: ["x"] }) + "\\n")
        #{emit("tool_call")}
      RUBY

      expect(result.text).to eq("分かったよ")
      expect(result.model).to eq("m")
      expect(result.structured).to be_nil
      expect(result.tool_events).to eq([
        { name: "semantic_search", args: { "query" => "猫" }, result: { results: "記憶", log: ["x"] } },
        { name: "web_search", args: { "query" => "東京 天気" },
          result: { answer: "東京の天気\nhttps://example.com/tokyo\n晴れ", log: ["[WebSearch] 東京 天気"] } },
        { name: "shell", args: { "command" => "/usr/bin/zsh -lc 'echo hello'" },
          result: { answer: "hello\n", log: ["[shell] /usr/bin/zsh -lc 'echo hello'"] } }
      ])
    end

    it "passes text written before a tool use as progress, but not the final answer" do
      progress = []
      runner(emit("tool_call")).run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m",
        on_progress: ->(text) { progress << text })

      expect(progress).to eq(["調べてみるね"])
    end

    it "returns the answer in the given shape, leaving out empty optional fields, without passing it as progress" do
      progress = []
      result = runner(emit("structured")).run(system_prompt: "S", prompt: "P", character: character, scene: :chat, model: "m",
        json_schema: ChatSession::REPLY_SCHEMA, on_progress: ->(text) { progress << text })

      expect(result.structured).to eq("reply" => "やあ", "next_action" => "wait_for_user")
      expect(progress).to be_empty
    end

    it "leaves the shape empty when the answer is not JSON" do
      result = runner(emit("tool_call")).run(system_prompt: "S", prompt: "P", model: "m", json_schema: { type: "object" })

      expect(result.structured).to be_nil
      expect(result.text).to eq("分かったよ")
    end

    it "raises with the API's message when the turn fails" do
      expect {
        runner(emit("turn_failed")).run(system_prompt: "S", prompt: "P", model: "m")
      }.to raise_error(ClaudeCli::Error, "Invalid schema for response_format 'codex_output_schema'.")
    end

    it "raises when codex cannot sign in" do
      expect {
        runner("#{emit("usage_limit")}; exit 1").run(system_prompt: "S", prompt: "P", model: "m")
      }.to raise_error(ClaudeCli::Error, /401 Unauthorized/)
    end

    it "raises with stderr when the output is not JSON" do
      expect {
        runner('warn "boom"; exit 2').run(system_prompt: "S", prompt: "P", model: "m")
      }.to raise_error(ClaudeCli::Error, /終了コード 2: boom/)
    end

    it "raises when the command is missing" do
      expect {
        ClaudeCli::Runner.new(backend: "codex", command: File.join(dir, "no_such_codex")).run(system_prompt: "S", prompt: "P", model: "m")
      }.to raise_error(ClaudeCli::Error, /見つかりません/)
    end
  end
end
