require "rails_helper"
require "puma"

# DiscordClient の契約を、実際の HTTP サーバー（Puma）に対して確かめる
RSpec.describe MemoriaServer::DiscordClient do
  let(:protocol) { MemoriaServer::DiscordProtocol }
  let(:requests) { [] }
  let(:script) { [] } # サーバーが返す、文字列か [:sleep, 秒] の並び
  let(:status) { 200 }

  # Rack のレスポンスのボディ（each でイベントを流す）
  def streaming_body(parts)
    Class.new do
      define_method(:each) do |&out|
        parts.each { |part| part.is_a?(Array) ? sleep(part[1]) : out.call(part) }
      end
    end.new
  end

  def start_server
    app = lambda do |env|
      requests << { auth: env["HTTP_AUTHORIZATION"], body: JSON.parse(env["rack.input"].read) }
      [ status, { "content-type" => "text/event-stream" }, streaming_body(script) ]
    end
    server = Puma::Server.new(app, nil, { min_threads: 1, max_threads: 2, log_writer: Puma::LogWriter.strings })
    server.add_tcp_listener("127.0.0.1", 0)
    server.run
    server
  end

  let!(:server) { start_server }
  let(:port) { server.connected_ports.first }
  let(:client) { described_class.new(base_url: "http://127.0.0.1:#{port}", token: "tok", read_timeout: 0.5, open_timeout: 1) }

  after { server.stop(true) }

  def reply(client = self.client)
    texts = []
    client.reply(channel_id: "C1", channel_name: "general", author_id: "U1", text: "やあ") { |text, last| texts << [ text, last ] }
    texts
  end

  it "message を出た順にブロックへ渡し、done で正常に戻る。鍵と発言をサーバーに送る" do
    script.push(protocol.encode("accepted", character: "ハル"), protocol::PING, protocol.encode("message", text: "調べるね", last: false),
                protocol.encode("message", text: "できたよ", last: true), protocol.encode("done"))

    expect(reply).to eq([ [ "調べるね", false ], [ "できたよ", true ] ])
    expect(requests.first).to eq(auth: "Bearer tok", body: { "channel_id" => "C1", "channel_name" => "general", "author_id" => "U1", "text" => "やあ" })
  end

  it "ping だけが続くあいだは、切れたとみなさない（read_timeout より長くかかっても待つ）" do
    script.push(protocol.encode("accepted"), protocol::PING, [ :sleep, 0.3 ], protocol::PING, [ :sleep, 0.3 ], protocol.encode("message", text: "遅くなった", last: true), protocol.encode("done"))

    expect(reply).to eq([ [ "遅くなった", true ] ])
  end

  it "done がないまま切れたら Interrupted（再送を促さない）" do
    script.push(protocol.encode("accepted"), protocol.encode("message", text: "途中まで", last: false))

    texts = []
    expect do
      client.reply(channel_id: "C1", channel_name: "g", author_id: "U1", text: "やあ") { |text, _| texts << text }
    end.to raise_error(described_class::Interrupted)
    expect(texts).to eq([ "途中まで" ])
  end

  it "何も来ない時間が read_timeout を超えたら Interrupted" do
    script.push(protocol.encode("accepted"), [ :sleep, 1.5 ])

    expect { reply }.to raise_error(described_class::Interrupted)
  end

  it "error イベントは Rejected にし、kind を持たせる" do
    script.push(protocol.encode("accepted"), protocol.encode("error", kind: "busy", message: "x"))

    expect { reply }.to raise_error(described_class::Rejected) { |e| expect(e.kind).to eq("busy") }
  end

  context "サーバーが HTTP のエラーを返すとき" do
    let(:status) { 401 }

    it "Rejected にする" do
      expect { reply }.to raise_error(described_class::Rejected) { |e| expect(e.kind).to eq("http_401") }
    end
  end

  it "接続できなければ Unavailable" do
    dead = described_class.new(base_url: "http://127.0.0.1:1", token: "tok", open_timeout: 1)

    expect { reply(dead) }.to raise_error(described_class::Unavailable)
  end

  describe ".failure_text（純粋関数）" do
    it "例外の種類ごとに、Discord に返す文を決める" do
      expect(described_class.failure_text(described_class::Unavailable.new)).to include("いまは返答できません")
      expect(described_class.failure_text(described_class::Interrupted.new)).to include("途中で切れました")
      expect(described_class.failure_text(described_class::Rejected.new("busy", "x"))).to include("まだ終わっていません")
      expect(described_class.failure_text(described_class::Rejected.new("failed", "limit"))).to include("limit")
      expect(described_class.failure_text(RuntimeError.new("boom"))).to include("RuntimeError: boom")
    end
  end
end
