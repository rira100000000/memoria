require "rails_helper"

RSpec.describe ChatSession, "with a persistent claude" do
  let(:vault_root) { Dir.mktmpdir }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "fake.log") }
  let(:character) { create(:character, name: "アオイ") }
  let(:record) { create(:chat_session_record, character: character) }
  let(:llm_client) { instance_double(LlmClient) }
  let(:pool) { PersistentClaude::Pool.instance }
  let(:env) do
    {
      "VAULT_ROOT" => vault_root, "MEMORIA_AGENT_BACKEND" => "claude_cli", "CLAUDE_CLI_PERSISTENT" => "1",
      "CLAUDE_CLI_COMMAND" => Rails.root.join("spec/fixtures/bin/fake_persistent_claude").to_s, "FAKE_CLAUDE_LOG" => log_path,
      "CLAUDE_CLI_MODEL" => "sonnet", "CLAUDE_CLI_DEEP_MODEL" => "opus", "CLAUDE_CLI_CHAT_MODEL" => "haiku",
      "CLAUDE_CLI_WORKDIR" => nil, "CLAUDE_CLI_SETTINGS" => nil, "LLM_CLI_BACKEND" => nil, "CLAUDE_CLI_LAZY_MCP" => "0"
    }
  end

  around do |example|
    original = env.keys.to_h { |key| [ key, ENV[key] ] }
    env.each { |key, value| ENV[key] = value }
    example.run
  ensure
    pool.shutdown
    original.each { |key, value| ENV[key] = value }
    FileUtils.remove_entry(vault_root)
    FileUtils.remove_entry(dir)
  end

  before do
    allow_any_instance_of(MemoriaCore::ContextRetriever).to receive(:retrieve).and_return({ llm_context_prompt: "記憶A" })
  end

  # リクエストごとに ChatSession は作り直される
  def session_for_request
    described_class.new(character, record: record.reload, llm_client: llm_client, platform: :discord)
  end

  def send_message(text)
    session_for_request.send_message(text)
  end

  def logged
    File.readlines(log_path).map { |line| JSON.parse(line) }
  end

  def system_prompt_of(entry)
    args = entry["args"]
    args[args.index("--system-prompt") + 1]
  end

  it "keeps what changes every turn out of the system prompt and puts it before the message" do
    send_message("やあ")

    first = logged.first
    expect(system_prompt_of(first)).not_to include("Current time is", "記憶A")
    expect(system_prompt_of(first)).to include(PromptBuilder::MEMORIA_INSTRUCTION.lines.first.strip, "You are a helpful assistant.")
    expect(first["content"]).to include("【システムが添えた背景", "Current time is", "記憶A", "【背景ここまで】", "Userの新しいメッセージ:\nやあ")
  end

  it "sends only what is new on the next turn, to the same claude" do
    first = send_message("やあ")
    second = send_message("元気？")

    entries = logged
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(1)
    expect(entries.last["content"]).to include("Current time is", "記憶A", "Userの新しいメッセージ:\n元気？")
    expect(entries.last["content"]).not_to include("これまでの会話:", "Userの新しいメッセージ:\nやあ")
    expect(first[:response]).to eq("echo1")
    expect(second[:response]).to eq("echo2")
  end

  it "tells the claude about what was said elsewhere in between" do
    send_message("やあ")
    record.reload
    record.append_message("user", "別の場所からの発言")
    record.append_message("model", "別の場所での返事")

    send_message("戻ったよ")

    prompt = logged.last["content"]
    expect(prompt).to include("別の場所であった会話", "User: 別の場所からの発言", "アオイ: 別の場所での返事", "Userの新しいメッセージ:\n戻ったよ")
    expect(prompt).not_to include("User: やあ")
    expect(logged.map { |e| e["pid"] }.uniq.size).to eq(1)
  end

  it "starts over from the full history when the history no longer matches what the claude saw" do
    send_message("やあ")
    record.reload.update!(messages: [ { "role" => "user", "content" => "まったく別の話" }, { "role" => "model", "content" => "そうなんだ" } ])

    send_message("続きだよ")

    entries = logged
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(2)
    expect(entries.last["content"]).to include("これまでの会話:", "User: まったく別の話", "Userの新しいメッセージ:\n続きだよ")
  end

  it "uses another claude for another conversation record" do
    send_message("やあ")
    record.update!(status: "closed")
    fresh_record = create(:chat_session_record, character: character, user: record.user)
    fresh = described_class.new(character, record: fresh_record, llm_client: llm_client, platform: :discord)

    fresh.send_message("はじめまして")

    entries = logged
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(2)
    expect(entries.last["content"]).not_to include("User: やあ")
  end

  it "uses a claude for the stronger model after switching, and stops the other one" do
    send_message("やあ")
    old_pid = logged.first["pid"]
    record.reload.update!(deep_mode: true)

    send_message("設計の話をしよう")

    entries = logged
    expect(entries.last["pid"]).not_to eq(old_pid)
    expect(entries.last["args"][entries.last["args"].index("--model") + 1]).to eq("opus")
    expect(entries.last["content"]).to include("これまでの会話:", "User: やあ")
    expect(pool.size).to eq(1)
  end

  it "does not repeat the schedules and the prospective memory when they have not changed" do
    allow_any_instance_of(described_class).to receive(:build_schedule_context).and_return("10:00 散歩")
    send_message("やあ")
    send_message("元気？")

    expect(logged.first["content"]).to include("10:00 散歩")
    expect(logged.last["content"]).not_to include("10:00 散歩")
  end

  it "repeats the schedules when they changed" do
    schedules = [ "10:00 散歩", "10:00 散歩\n12:00 昼ごはん" ].each
    allow_any_instance_of(described_class).to receive(:build_schedule_context) { schedules.next }
    send_message("やあ")
    send_message("元気？")

    expect(logged.last["content"]).to include("12:00 昼ごはん")
  end

  it "carries on with the claude when it continues with a next step, without repeating what it said" do
    result = send_message("CONTINUE してね")

    entries = logged
    expect(entries.size).to eq(2)
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(1)
    expect(entries.last["content"]).to include("次の作業", "Userからの新しいメッセージはない")
    expect(entries.last["content"]).not_to include("これまでの会話:", "別の場所であった会話")
    expect(result[:response]).to eq("続けるね\n\necho2")
  end

  it "keeps the claude after a continued turn, knowing what it said" do
    send_message("CONTINUE してね")
    send_message("ありがとう")

    entries = logged
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(1)
    expect(entries.last["content"]).not_to include("別の場所であった会話")
  end

  it "answers that it could not reply when the claude dies, and starts a new one next time" do
    crash_once = File.join(dir, "crash_once")
    File.write(crash_once, "")
    ENV["FAKE_CRASH_ONCE"] = crash_once
    reply = send_message("CRASH")

    expect(reply[:response]).to include("返答できませんでした")
    expect(pool.size).to eq(0)

    expect(send_message("もう一度")[:response]).to eq("echo1")
  ensure
    ENV.delete("FAKE_CRASH_ONCE")
  end

  it "records the replies in the conversation as usual" do
    send_message("やあ")
    send_message("元気？")

    expect(record.reload.messages.map { |m| [ m["role"], m["content"] ] }).to eq(
      [ [ "user", "やあ" ], [ "model", "echo1" ], [ "user", "元気？" ], [ "model", "echo2" ] ]
    )
  end

  it "does not keep a claude when persistence is off" do
    ENV["CLAUDE_CLI_PERSISTENT"] = nil
    allow(ClaudeCli::Runner).to receive(:new).and_wrap_original { |original, **opts| original.call(**opts) }

    expect(session_for_request.send(:persistent_claude?)).to be(false)
  end

  it "starts over from the history when the reply was given but could not be stored" do
    send_message("やあ")
    calls = 0
    allow_any_instance_of(ChatSessionRecord).to receive(:append_message).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise ActiveRecord::StatementInvalid, "database is locked" if args.first == "model" && calls == 2
      original.call(*args, **kwargs)
    end
    expect { send_message("二つ目") }.to raise_error(ActiveRecord::StatementInvalid)
    allow_any_instance_of(ChatSessionRecord).to receive(:append_message).and_call_original

    send_message("三つ目")

    entries = logged
    expect(entries.last["content"]).to include("これまでの会話:", "User: 二つ目", "Userの新しいメッセージ:\n三つ目")
    expect(entries.last["content"]).not_to include("別の場所であった会話")
    expect(entries.map { |e| e["pid"] }.uniq.size).to eq(2)
  end

  it "tells the claude that the schedules are gone once they become empty" do
    schedules = [ "10:00 散歩", "" ].each
    allow_any_instance_of(described_class).to receive(:build_schedule_context) { schedules.next }
    send_message("やあ")
    send_message("元気？")

    expect(logged.first["content"]).to include("10:00 散歩")
    expect(logged.last["content"]).to include("いまは予定がない", "すべてなくなった")
  end

  it "does not repeat the memory when the claude carries on with a next step" do
    send_message("CONTINUE してね")

    entries = logged
    expect(entries.first["content"]).to include("記憶A")
    expect(entries.last["content"]).not_to include("記憶A")
    expect(entries.last["content"]).to include("Current time is")
  end

  describe "when the route and the wanted capabilities change between requests" do
    let(:expression) { MemoriaServer::Capability.find(:expression) }

    def request(text, platform:, channel:, wants: [])
      session = described_class.new(character, record: record.reload, llm_client: llm_client, platform: platform, channel: channel)
      session.add_reply_capabilities(wants)
      session.send_message(text)
    end

    def schema_of(entry)
      args = entry["args"]
      JSON.parse(args[args.index("--json-schema") + 1])
    end

    it "uses one claude for one conversation record, telling the route and the wanted fields each turn" do
      request("やあ", platform: :discord, channel: "Discord #general")
      request("こんにちは", platform: nil, channel: "API", wants: [ expression ])

      first, second = logged
      expect(second["pid"]).to eq(first["pid"])
      expect(first["content"]).to include("あなたは現在、Discord #generalを通じて会話しています。", "expression の項目は付けない")
      expect(second["content"]).to include("あなたは現在、APIを通じて会話しています。", "立ち絵に出す表情と演出")
      expect(second["content"]).not_to include("expression の項目は付けない")
    end

    it "keeps the route and the capability instructions out of the system prompt, which stays the same" do
      request("やあ", platform: :discord, channel: "Discord #general")

      system_prompt = system_prompt_of(logged.first)
      expect(system_prompt).not_to include("Discord #general", "立ち絵に出す表情と演出")
    end

    it "starts the claude with a reply shape that has every capability field, none of them required" do
      request("やあ", platform: :discord, channel: "Discord #general")

      schema = schema_of(logged.first)
      expect(schema["properties"].keys).to include("reply", "next_action", "expression")
      expect(schema["required"]).to eq(%w[reply next_action])
    end

    it "hands back the capability value only for the request that wanted it" do
      allow_any_instance_of(PersistentClaude::Session).to receive(:turn).and_wrap_original do |original, *args, **kwargs|
        out = original.call(*args, **kwargs)
        out.merge(stdout: out[:stdout].gsub('"reply":"echo', '"expression":{"face":"joy","emote":"none"},"reply":"echo'))
      end

      plain = request("やあ", platform: :discord, channel: "Discord #general")
      wanted = request("こんにちは", platform: nil, channel: "API", wants: [ expression ])

      expect(plain[:extras]).to eq({})
      expect(wanted[:extras]).to eq(expression: { face: "joy", emote: "none" })
    end
  end
end
