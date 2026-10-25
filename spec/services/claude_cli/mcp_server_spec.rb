require "rails_helper"

RSpec.describe ClaudeCli::McpServer do
  let(:provider) do
    Class.new do
      def tools
        [{ name: "echo", description: "echo", parameters: { type: "OBJECT", properties: { text: { type: "STRING" } } } }]
      end

      def call(name, args)
        raise "boom" if args["text"] == "boom"
        return { error: "bad" } if args["text"] == "bad"

        { echoed: args["text"], log: ["ログ"] }
      end
    end.new
  end
  let(:events_path) { Rails.root.join("tmp", "mcp_events_#{SecureRandom.hex(4)}.jsonl").to_s }
  let(:server) { described_class.new(provider: provider, events_path: events_path) }

  after { FileUtils.rm_f(events_path) }

  def request(id, method, params = {})
    JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
  end

  it "answers initialize with the client's protocol version" do
    response = server.handle(request(1, "initialize", { protocolVersion: "2025-03-26" }))

    expect(response[:result][:protocolVersion]).to eq("2025-03-26")
    expect(response[:result][:capabilities]).to eq(tools: {})
  end

  it "does not answer notifications" do
    expect(server.handle(JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"))).to be_nil
  end

  it "lists tools as JSON Schema" do
    tools = server.handle(request(2, "tools/list"))[:result][:tools]

    expect(tools).to eq([{ name: "echo", description: "echo",
                           inputSchema: { type: "object", properties: { text: { type: "string" } } } }])
  end

  it "calls a tool, hides :log from the LLM and records the event" do
    result = server.handle(request(3, "tools/call", { name: "echo", arguments: { text: "hi" } }))[:result]

    expect(JSON.parse(result[:content].first[:text])).to eq("echoed" => "hi")
    expect(result[:isError]).to be(false)
    event = JSON.parse(File.read(events_path))
    expect(event).to eq("name" => "echo", "args" => { "text" => "hi" }, "result" => { "echoed" => "hi", "log" => ["ログ"] })
  end

  it "turns exceptions and error results into tool errors" do
    raised = server.handle(request(4, "tools/call", { name: "echo", arguments: { text: "boom" } }))[:result]
    errored = server.handle(request(5, "tools/call", { name: "echo", arguments: { text: "bad" } }))[:result]

    expect(raised[:isError]).to be(true)
    expect(raised[:content].first[:text]).to include("boom")
    expect(errored[:isError]).to be(true)
  end

  describe "usage log" do
    let(:usage_path) { Rails.root.join("tmp", "tool_usage_#{SecureRandom.hex(4)}", "usage.jsonl").to_s }
    let(:usage_log) { ClaudeCli::ToolUsageLog.new(path: usage_path, scene: "chat", trigger: "user_message", platform: "discord", character_id: 5) }
    let(:server) { described_class.new(provider: provider, events_path: events_path, usage_log: usage_log) }

    after { FileUtils.rm_rf(File.dirname(usage_path)) }

    def usage_entries
      File.readlines(usage_path).map { |l| JSON.parse(l) }
    end

    it "records each tool call without its arguments or result" do
      server.handle(request(1, "tools/call", { name: "echo", arguments: { text: "秘密" } }))
      server.handle(request(2, "tools/call", { name: "echo", arguments: { text: "bad" } }))
      server.handle(request(3, "tools/call", { name: "echo", arguments: { text: "boom" } }))

      entries = usage_entries
      expect(entries.map { |e| e["ok"] }).to eq([true, false, false])
      expect(entries.first).to include("tool" => "echo", "scene" => "chat", "trigger" => "user_message",
        "platform" => "discord", "character_id" => 5)
      expect(entries.first["ms"]).to be_a(Integer)
      expect(File.read(usage_path)).not_to include("秘密")
    end

    it "does not record tools/list or other requests" do
      server.handle(request(1, "tools/list"))
      server.handle(request(2, "ping"))

      expect(File.exist?(usage_path)).to be(false)
    end

    it "still answers when the usage log cannot be written" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(usage_path, "a", encoding: "utf-8").and_raise(Errno::EACCES)
      allow(Rails.logger).to receive(:warn)

      result = server.handle(request(1, "tools/call", { name: "echo", arguments: { text: "hi" } }))[:result]

      expect(JSON.parse(result[:content].first[:text])).to eq("echoed" => "hi")
      expect(Rails.logger).to have_received(:warn).with(a_string_including("ToolUsageLog"))
    end
  end

  it "rejects unknown methods and broken JSON" do
    expect(server.handle(request(6, "resources/list"))[:error][:code]).to eq(-32601)
    expect(server.handle("{oops")[:error][:code]).to eq(-32700)
  end

  it "reads requests line by line from input and writes responses" do
    input = StringIO.new([request(1, "ping"), "", request(2, "tools/list")].join("\n"))
    output = StringIO.new

    described_class.new(provider: provider, input: input, output: output).run

    ids = output.string.lines.map { |l| JSON.parse(l)["id"] }
    expect(ids).to eq([1, 2])
  end
end
