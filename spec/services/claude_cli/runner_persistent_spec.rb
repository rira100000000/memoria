require "rails_helper"

RSpec.describe ClaudeCli::Runner, "keeping claude running" do
  let(:character) { create(:character) }
  let(:record) { create(:chat_session_record, character: character) }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "fake.log") }
  let(:fake) { Rails.root.join("spec/fixtures/bin/fake_persistent_claude").to_s }
  let(:schema) { ChatSession::REPLY_SCHEMA }
  let(:pool) { PersistentClaude::Pool.instance }
  let(:fresh_prompts) { [] }
  let(:resume_seen) { [] }
  let(:verify_with) { ->(_seen) { true } }

  before { ENV["FAKE_CLAUDE_LOG"] = log_path }

  after do
    pool.shutdown
    ENV.delete("FAKE_CLAUDE_LOG")
    FileUtils.remove_entry(dir)
  end

  def runner(**opts)
    described_class.new(command: fake, persistent: true, lazy_mcp: false, **opts)
  end

  def persistence(**override)
    {
      record_id: record.id,
      verify: ->(seen) { verify_with.call(seen) },
      fresh_prompt: -> { fresh_prompts << 1 && "全文" },
      resume_prompt: ->(seen) { resume_seen << seen && "続き" }
    }.merge(override)
  end

  def run(runner, model: "haiku", **opts)
    runner.run(system_prompt: "S", prompt: "unused", model: model, character: character, scene: :chat, platform: :discord,
               json_schema: schema, persistence: persistence, **opts)
  end

  def logged
    File.readlines(log_path).map { |line| JSON.parse(line) }
  end

  it "uses one claude for several turns, sending the full prompt first and the continuation after" do
    r = runner
    first = run(r)
    pool.fetch(first.session_key).seen = { count: 2, tail: "x" }
    second = run(r)

    expect(first.structured["pid"]).to eq(second.structured["pid"])
    expect(logged.map { |entry| entry["content"] }).to eq(%w[全文 続き])
    expect(fresh_prompts.size).to eq(1)
    expect(resume_seen).to eq([ { count: 2, tail: "x" } ])
    expect(second.session_key).to eq(first.session_key)
    expect(pool.size).to eq(1)
  end

  it "starts claude for a conversation with stream-json input and the record id for the MCP server" do
    run(runner)

    args = logged.first["args"]
    expect(args).to include("--input-format", "stream-json", "-p", "--output-format")
    config = JSON.parse(File.read(args[args.index("--mcp-config") + 1])).dig("mcpServers", "memoria")
    expect(config["args"]).to include("--record-id", record.id.to_s)
  end

  it "respawns from the full history when verification fails" do
    r = runner
    first = run(r)
    session = pool.fetch(first.session_key)
    session.seen = { count: 2, tail: "x" }

    second = r.run(system_prompt: "S", prompt: "unused", model: "haiku", character: character, scene: :chat, platform: :discord,
                   json_schema: schema, persistence: persistence(verify: ->(_seen) { false }))

    expect(second.structured["pid"]).not_to eq(first.structured["pid"])
    expect(second.structured["n"]).to eq(1)
    expect(logged.map { |entry| entry["content"] }).to eq(%w[全文 全文])
    expect(session).not_to be_alive
    expect(pool.size).to eq(1)
  end

  it "reads only this turn's tool events from the shared events file" do
    r = runner
    first = run(r, usage_context: nil)
    pool.fetch(first.session_key).seen = { count: 1, tail: "x" }
    both = r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
                 json_schema: schema, persistence: persistence(fresh_prompt: -> { "TOOL" }, resume_prompt: ->(_) { "TOOL" }))
    third = r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
                  json_schema: schema, persistence: persistence(resume_prompt: ->(_) { "TOOL" }))

    expect(first.tool_events).to eq([])
    expect(both.tool_events.map { |e| e[:args] }).to eq([ { "query" => "n2" } ])
    pool.fetch(both.session_key).seen = { count: 2, tail: "y" }
    expect(third.tool_events.map { |e| e[:args] }).to eq([ { "query" => "n3" } ])
  end

  it "stops the claude of the same record when the model changes, and starts one for the new model" do
    r = runner
    haiku = run(r, model: "haiku")
    old = pool.fetch(haiku.session_key)

    opus = run(r, model: "opus")

    expect(old).not_to be_alive
    expect(opus.structured["pid"]).not_to eq(haiku.structured["pid"])
    expect(pool.size).to eq(1)
  end

  it "starts a separate claude when the system prompt changes" do
    r = runner
    first = r.run(system_prompt: "S1", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord, json_schema: schema, persistence: persistence)
    second = r.run(system_prompt: "S2", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord, json_schema: schema, persistence: persistence)

    expect(first.session_key).not_to eq(second.session_key)
    expect(pool.size).to eq(1)
  end

  it "keys the claude by the conversation record" do
    other = create(:chat_session_record) # 別の会話の記録（同じキャラクターには、有効な記録は1つしか作れない）
    r = runner
    a = run(r)
    b = r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
              json_schema: schema, persistence: persistence(record_id: other.id))

    expect(a.session_key).not_to eq(b.session_key)
    expect(a.structured["pid"]).not_to eq(b.structured["pid"])
  end

  it "discards the claude when a turn fails, and the next turn starts a new one" do
    r = runner
    first = run(r)
    session = pool.fetch(first.session_key)
    session.seen = { count: 1, tail: "x" }

    expect {
      r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
            json_schema: schema, persistence: persistence(resume_prompt: ->(_) { "CRASH" }))
    }.to raise_error(ClaudeCli::Error)
    expect(pool.size).to eq(0)

    again = run(r)
    expect(again.structured["pid"]).not_to eq(first.structured["pid"])
  end

  it "does not keep a claude that remembers too much, so the next turn starts from the history" do
    r = runner(max_context: 100)
    result = run(r)

    expect(result.session_key).to be_nil
    expect(pool.size).to eq(0)
  end

  it "waits for background work and does not keep that claude" do
    r = runner
    result = r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
                   json_schema: schema, persistence: persistence(fresh_prompt: -> { "BACKGROUND" }))

    expect(result.followups.map { |f| f[:structured]["reply"] }).to eq([ "後報" ])
    expect(result.session_key).to be_nil
    expect(pool.size).to eq(0)
  end

  it "relays text written before using a tool, for each turn separately" do
    texts = []
    r = runner
    first = r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
                  json_schema: schema, on_progress: ->(text) { texts << text }, persistence: persistence(fresh_prompt: -> { "PROGRESS" }))
    pool.fetch(first.session_key).seen = { count: 1, tail: "x" }
    r.run(system_prompt: "S", prompt: "u", model: "haiku", character: character, scene: :chat, platform: :discord,
          json_schema: schema, on_progress: ->(text) { texts << text }, persistence: persistence(resume_prompt: ->(_) { "PROGRESS" }))

    expect(texts).to eq(%w[調べてみるね 調べてみるね])
  end

  it "runs the way it did when persistence is not asked for, or for other scenes" do
    r = runner
    # 偽の claude は常駐用なので、-p のプロンプトを標準入力から1回読む従来の実行は別のテスト（runner_spec）で確かめている。
    # ここでは、常駐の判定だけを確かめる
    expect(r.send(:persistent_run?, character, :chat, schema)).to be_truthy
    expect(r.send(:persistent_run?, character, :thinking, schema)).to be_falsey
    expect(r.send(:persistent_run?, nil, :chat, schema)).to be_falsey
    expect(r.send(:persistent_run?, character, :chat, nil)).to be_falsey
    expect(described_class.new(command: fake, persistent: false).send(:persistent_run?, character, :chat, schema)).to be_falsey
  end
end
