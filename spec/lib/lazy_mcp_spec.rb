require "rails_helper"
require Rails.root.join("lib/lazy_mcp")

RSpec.describe LazyMcp::Frontend do
  let(:dir) { Dir.mktmpdir }
  let(:tools) { [ { "name" => "semantic_search", "description" => "探す", "inputSchema" => { "type" => "object" } } ] }
  let(:tools_path) { File.join(dir, "tools.json").tap { |path| File.write(path, JSON.generate(tools)) } }
  let(:server) { instance_double(ClaudeCli::McpServer) }
  let(:boots) { [] }
  let(:boot) { -> { boots << 1 && server } }
  let(:frontend) { described_class.new(tools_path: tools_path, boot: boot) }

  after { FileUtils.remove_entry(dir) }

  def call(method, params = {}, id: 1)
    frontend.handle(JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params))
  end

  it "answers initialize, ping and tools/list without starting the server" do
    expect(call("initialize", { protocolVersion: "2025-06-18" })).to eq(
      jsonrpc: "2.0", id: 1,
      result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "memoria", version: "1" } }
    )
    expect(call("ping")).to eq(jsonrpc: "2.0", id: 1, result: {})
    expect(call("tools/list")).to eq(jsonrpc: "2.0", id: 1, result: { tools: tools })
    expect(boots).to be_empty
  end

  it "answers the same way as the real server" do
    real = ClaudeCli::McpServer.new(provider: instance_double("provider", tools: []))

    expect(call("initialize", { protocolVersion: "2025-06-18" })).to eq(real.handle(JSON.generate(id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" })))
    expect(call("initialize")).to eq(real.handle(JSON.generate(id: 1, method: "initialize")))
    expect(call("ping")).to eq(real.handle(JSON.generate(id: 1, method: "ping")))
  end

  it "ignores notifications and reports a parse error" do
    expect(frontend.handle(JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"))).to be_nil
    expect(frontend.handle("{broken")).to include(error: { code: -32700, message: "Parse error" })
    expect(boots).to be_empty
  end

  it "starts the server once at the first tool call and hands every later line to it" do
    allow(server).to receive(:handle).and_return({ jsonrpc: "2.0", id: 3, result: { content: [] } })
    line = JSON.generate(jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "semantic_search", arguments: {} })

    expect(frontend.handle(line)).to eq(jsonrpc: "2.0", id: 3, result: { content: [] })
    frontend.handle(line)
    frontend.handle(JSON.generate(jsonrpc: "2.0", id: 4, method: "tools/list"))

    expect(boots.size).to eq(1)
    expect(server).to have_received(:handle).exactly(3).times
  end

  it "turns a failed start into an error for that call, without raising, and does not retry" do
    attempts = 0
    failing_boot = lambda do
      attempts += 1
      raise ActiveRecord::RecordNotFound, "no character"
    end
    frontend = described_class.new(tools_path: tools_path, boot: failing_boot)

    2.times do
      response = frontend.handle(JSON.generate(jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "x" }))
      expect(response[:error]).to include(code: -32603, message: a_string_including("failed to start", "RecordNotFound"))
    end
    expect(attempts).to eq(1)
  end

  it "raises for a missing or malformed tool list so the caller can start eagerly" do
    expect { described_class.new(tools_path: File.join(dir, "none.json"), boot: boot) }.to raise_error(Errno::ENOENT)
    File.write(File.join(dir, "bad.json"), "{broken")
    expect { described_class.new(tools_path: File.join(dir, "bad.json"), boot: boot) }.to raise_error(JSON::ParserError)
    File.write(File.join(dir, "obj.json"), "{}")
    expect { described_class.new(tools_path: File.join(dir, "obj.json"), boot: boot) }.to raise_error(ArgumentError)
  end

  it "runs the line loop and writes each response" do
    input = StringIO.new([
      JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: {}),
      JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"),
      JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list")
    ].join("\n") + "\n")
    output = StringIO.new

    described_class.new(tools_path: tools_path, boot: boot, input: input, output: output).run

    ids = output.string.lines.map { |l| JSON.parse(l)["id"] }
    expect(ids).to eq([ 1, 2 ])
    expect(boots).to be_empty
  end

  it "does not load Rails when bin/memoria_mcp answers initialize and tools/list" do
    require "open3"
    env = { "MEMORIA_MCP_TOOLS" => tools_path, "RAILS_ENV" => "test" }
    input = [
      JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" }),
      JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"),
      JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list")
    ].join("\n") + "\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    out, err, status = Open3.capture3(env, Rails.root.join("bin/memoria_mcp").to_s, "--character", "999999", "--scene", "chat", stdin_data: input)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(status).to be_success, err
    expect(out.lines.map { |l| JSON.parse(l)["id"] }).to eq([ 1, 2 ])
    expect(JSON.parse(out.lines.last).dig("result", "tools")).to eq(tools)
    expect(elapsed).to be < 1.5 # Rails を読み込むと、これだけでは終わらない
  end
end
