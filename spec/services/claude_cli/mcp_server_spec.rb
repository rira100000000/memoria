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
