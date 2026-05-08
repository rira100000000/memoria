require "rails_helper"

RSpec.describe MemoriaServer::Adapters::Http do
  let(:base_url) { "http://test-adapter.local:8080" }
  subject(:adapter) { described_class.new(base_url: base_url) }

  describe "#respond" do
    it "parses ndjson stream into chunks" do
      ndjson = <<~LINES
        {"delta":"Hello"}
        {"delta":" world","emotion":"happy"}
        {"done":true,"metadata":{"usage":{"input_tokens":10}}}
      LINES

      stub_request(:post, "#{base_url}/respond")
        .with(body: hash_including("input" => "hi"))
        .to_return(status: 200, body: ndjson, headers: { "Content-Type" => "application/x-ndjson" })

      chunks = adapter.respond("hi", context: { character_id: 1 }).to_a
      expect(chunks[0]).to eq({ delta: "Hello" })
      expect(chunks[1]).to eq({ delta: " world", emotion: "happy" })
      expect(chunks[2]).to eq({ done: true, metadata: { "usage" => { "input_tokens" => 10 } } })
    end

    it "yields tool_calls chunks" do
      ndjson = <<~LINES
        {"tool_calls":[{"id":"c1","function":{"name":"f"}}]}
        {"done":true}
      LINES
      stub_request(:post, "#{base_url}/respond")
        .to_return(status: 200, body: ndjson)

      chunks = adapter.respond("x", context: { character_id: 1 }).to_a
      expect(chunks[0][:tool_calls]).to be_an(Array)
    end

    it "raises on non-2xx response" do
      stub_request(:post, "#{base_url}/respond")
        .to_return(status: 500, body: "boom")
      expect {
        adapter.respond("x", context: { character_id: 1 }).to_a
      }.to raise_error(MemoriaServer::Error, /HTTP adapter returned 500/)
    end

    it "ISO-formats Time in last_interaction_at when serializing context" do
      now = Time.current
      stub_request(:post, "#{base_url}/respond")
        .with(body: hash_including("context" => hash_including("last_interaction_at" => now.iso8601)))
        .to_return(status: 200, body: %({"done":true}\n))
      adapter.respond("hi", context: { character_id: 1, last_interaction_at: now }).to_a
    end
  end

  describe "#on_boundary" do
    it "POSTs to /boundary" do
      stub_request(:post, "#{base_url}/boundary")
        .with(body: { character_id: 42, reason: "user" }.to_json)
        .to_return(status: 200, body: '{"ok":true}')
      result = adapter.on_boundary(character_id: 42, reason: "user")
      expect(result["ok"]).to be true
    end

    it "returns nil if remote returns 404 (not implemented)" do
      stub_request(:post, "#{base_url}/boundary").to_return(status: 404)
      expect(adapter.on_boundary(character_id: 42, reason: "user")).to be_nil
    end
  end

  describe "#history" do
    it "returns messages array" do
      stub_request(:post, "#{base_url}/history")
        .to_return(status: 200, body: '{"messages":[{"role":"user","content":"hi"}]}')
      msgs = adapter.history(character_id: 42)
      expect(msgs.first["role"]).to eq("user")
    end

    it "returns [] if remote returns 404" do
      stub_request(:post, "#{base_url}/history").to_return(status: 404)
      expect(adapter.history(character_id: 42)).to eq([])
    end
  end

  describe ".new" do
    it "raises when base_url not set" do
      expect { described_class.new(base_url: "") }.to raise_error(MemoriaServer::Error, /MS_ADAPTER_URL/)
    end
  end
end
