require "rails_helper"

RSpec.describe ChatSession, "with the claude -p backend" do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character, name: "アオイ") }
  let(:record) { create(:chat_session_record, character: character) }
  let(:llm_client) { instance_double(LlmClient) }
  let(:session) { described_class.new(character, record: record, llm_client: llm_client, platform: :discord) }
  let(:runner) { instance_double(ClaudeCli::Runner) }

  def claude_result(text, events = [], structured: nil)
    ClaudeCli::Runner::Result.new(text: text, tool_events: events, model: "x", structured: structured)
  end

  def structured_reply(reply, next_action, next_step = nil)
    claude_result(JSON.generate(reply: reply), structured: { "reply" => reply, "next_action" => next_action, "next_step" => next_step }.compact)
  end

  around do |example|
    original = ENV.to_h.slice("VAULT_ROOT", "MEMORIA_AGENT_BACKEND", "CLAUDE_CLI_MODEL", "CLAUDE_CLI_DEEP_MODEL")
    ENV["VAULT_ROOT"] = vault_root
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"
    ENV["CLAUDE_CLI_MODEL"] = "sonnet"
    ENV["CLAUDE_CLI_DEEP_MODEL"] = "opus"
    example.run
  ensure
    %w[VAULT_ROOT MEMORIA_AGENT_BACKEND CLAUDE_CLI_MODEL CLAUDE_CLI_DEEP_MODEL].each { |k| ENV[k] = original[k] }
    FileUtils.remove_entry(vault_root)
  end

  before do
    allow_any_instance_of(MemoriaCore::ContextRetriever).to receive(:retrieve).and_return({ llm_context_prompt: "" })
    allow(ClaudeCli::Runner).to receive(:new).and_return(runner)
  end

  it "answers with claude -p, passing the conversation so far" do
    record.update!(messages: [{ "role" => "user", "content" => "前の話" }, { "role" => "model", "content" => "前の返事" }])
    allow(runner).to receive(:run).and_return(claude_result("こんにちは"))

    result = session.send_message("やあ")

    expect(result[:response]).to eq("こんにちは")
    expect(record.reload.messages.last).to eq("role" => "model", "content" => "こんにちは")
    expect(runner).to have_received(:run).with(hash_including(
      scene: :chat, platform: :discord, model: "sonnet", character: character,
      prompt: a_string_including("User: 前の話", "アオイ: 前の返事", "Userの新しいメッセージ:\nやあ")
    ))
  end

  it "tells the character that a reply ends its turn and where earlier conversations are" do
    allow(runner).to receive(:run).and_return(claude_result("ok"))

    session.send_message("やあ")

    expect(runner).to have_received(:run).with(hash_including(
      system_prompt: a_string_including("next_action で必ず選ぶ", File.join(character.vault_path, "FullLog")),
      json_schema: ChatSession::REPLY_SCHEMA
    ))
  end

  it "answers with the reply field of the structured answer" do
    allow(runner).to receive(:run).and_return(structured_reply("こんにちは", "wait_for_user"))

    result = session.send_message("やあ")

    expect(result[:response]).to eq("こんにちは")
    expect(runner).to have_received(:run).once
  end

  it "sends the reply and runs again at once when the character chose to continue" do
    replies = [structured_reply("入れてくる", "continue", "ffmpeg を入れる"), structured_reply("入れたよ", "wait_for_user")]
    allow(runner).to receive(:run) { replies.shift }
    progress = []

    result = session.send_message("おｋ", on_progress: ->(text) { progress << text })

    expect(progress).to eq(["入れてくる"])
    expect(result[:response]).to eq("入れたよ")
    expect(record.reload.messages.map { |m| m["content"] }).to eq(%w[おｋ 入れてくる 入れたよ])
    expect(runner).to have_received(:run).with(hash_including(
      prompt: a_string_including("アオイ: 入れてくる", "続けると決めた作業:\nffmpeg を入れる")
    ))
  end

  it "puts the replies together when progress cannot be sent" do
    replies = [structured_reply("入れてくる", "continue", "ffmpeg を入れる"), structured_reply("入れたよ", "wait_for_user")]
    allow(runner).to receive(:run) { replies.shift }

    result = session.send_message("おｋ")

    expect(result[:response]).to eq("入れてくる\n\n入れたよ")
    expect(record.reload.messages.map { |m| m["content"] }).to eq(%w[おｋ 入れてくる 入れたよ])
  end

  it "stops continuing after a few runs" do
    allow(runner).to receive(:run).and_return(structured_reply("まだやる", "continue", "続き"))

    session.send_message("やって", on_progress: ->(_) { })

    expect(runner).to have_received(:run).exactly(ChatSession::MAX_CONTINUATIONS + 1).times
  end

  it "writes tool logs to the full log" do
    allow(runner).to receive(:run).and_return(claude_result("ok", [{ name: "talk_to_pet", args: {}, result: { log: ["ピコ: ぴよ"] } }]))
    allow(session.chat_logger).to receive(:log_ai_message).and_call_original

    session.send_message("やあ")

    expect(session.chat_logger).to have_received(:log_ai_message).with("ピコ: ぴよ")
  end

  it "keeps the work done before a reply and passes it to the next answer" do
    bash = { name: "Bash", args: {}, result: { log: ["[Bash] python3 tools/gen.py ref.png out.png"] } }
    allow(runner).to receive(:run).and_return(claude_result("できたよ", [bash]), claude_result("もう1枚ね"))

    session.send_message("1枚作って")
    session.send_message("もう1枚")

    expect(record.reload.messages[1]).to eq("role" => "model", "content" => "できたよ",
                                            "work" => ["[Bash] python3 tools/gen.py ref.png out.png"])
    expect(record.messages.last).to eq("role" => "model", "content" => "もう1枚ね")
    expect(runner).to have_received(:run).with(hash_including(
      prompt: a_string_including("User: 1枚作って\n（アオイの作業）[Bash] python3 tools/gen.py ref.png out.png\nアオイ: できたよ",
                                 "同じ下調べを繰り返さない")
    ))
  end

  it "hands progress to the caller and writes it to the full log" do
    allow(runner).to receive(:run) do |**kwargs|
      kwargs[:on_progress].call("調べてみるね")
      claude_result("分かったよ")
    end
    allow(session.chat_logger).to receive(:log_ai_message).and_call_original
    progress = []

    result = session.send_message("やあ", on_progress: ->(text) { progress << text })

    expect(progress).to eq(["調べてみるね"])
    expect(result[:response]).to eq("分かったよ")
    expect(session.chat_logger).to have_received(:log_ai_message).with("調べてみるね").ordered
    expect(session.chat_logger).to have_received(:log_ai_message).with("分かったよ").ordered
  end

  describe ".record_outgoing" do
    include ActiveJob::TestHelper

    it "starts a chat with the message, keeps it open for a reply, and passes it to the next answer" do
      allow(runner).to receive(:run).and_return(claude_result("よかった"))

      outgoing = nil
      expect {
        outgoing = described_class.record_outgoing(character, "調べ終わったよ")
      }.to have_enqueued_job(ConversationTimeoutJob).with(kind_of(Integer), 1)

      expect(outgoing.record.messages).to eq([{ "role" => "model", "content" => "調べ終わったよ" }])
      reply = described_class.find_or_create(character, character.user, platform: :discord)
      expect(reply.record).to eq(outgoing.record)
      reply.send_message("ありがとう")
      expect(runner).to have_received(:run).with(hash_including(prompt: a_string_including("アオイ: 調べ終わったよ", "ありがとう")))
    end

    it "adds the message to the chat that is going on" do
      allow(runner).to receive(:run).and_return(claude_result("うん"))
      session.send_message("やあ")

      described_class.record_outgoing(character, "そういえば")

      expect(record.reload.messages.map { |m| m["content"] }).to eq(%w[やあ うん そういえば])
    end

    it "does not reflect on a chat that only has messages nobody answered" do
      outgoing = described_class.record_outgoing(character, "おはよう")
      outgoing.append_outgoing("今日の予定だよ")
      expect(ReflectionService).not_to receive(:new)

      outgoing.reset!
    end
  end

  it "redoes the answer with the deep model when the character switched during the run" do
    calls = []
    allow(runner).to receive(:run) do |**kwargs|
      calls << kwargs[:model]
      record.update!(deep_mode: true) if kwargs[:model] == "sonnet" # use_deep_model を呼んだのと同じ
      claude_result("#{kwargs[:model]}の返事")
    end

    result = session.send_message("設計の相談なんだけど")

    expect(calls).to eq(%w[sonnet opus])
    expect(result[:response]).to eq("opusの返事")
  end

  it "keeps using the deep model for the rest of the session" do
    record.update!(deep_mode: true)
    allow(runner).to receive(:run).and_return(claude_result("ok"))

    session.send_message("続き")

    expect(runner).to have_received(:run).once.with(hash_including(model: "opus"))
  end

  it "offers use_deep_model only until it is used" do
    names = -> { session.tool_definitions.first[:functionDeclarations].map { |f| f[:name] } }
    expect(names.call).to include("use_deep_model")

    expect(session.call_tool("use_deep_model", { "reason" => "設計" })).to include(switched: true, model: "opus")
    expect(record.reload.deep_mode).to be(true)
    expect(names.call).not_to include("use_deep_model")
  end

  describe "#send_event" do
    it "answers an event in the conversation, seeing everything said so far" do
      long_report = "作業が終わったよ。" + "中身の説明。" * 100
      record.update!(messages: [{ "role" => "user", "content" => "直して" }, { "role" => "model", "content" => long_report }])
      allow(runner).to receive(:run).and_return(structured_reply("反映できたよ", "wait_for_user"))

      result = session.send_event("起きた理由: 反映した")

      expect(result[:response]).to eq("反映できたよ")
      expect(record.reload.messages.map { |m| m["content"] }).to eq(["直して", long_report, "反映できたよ"])
      expect(runner).to have_received(:run).with(hash_including(
        prompt: a_string_including("User: 直して", "アオイ: #{long_report}", "次の出来事であなたが起こされた:\n起きた理由: 反映した",
          "すでに伝えたことは繰り返さず")
      ))
    end

    it "keeps going in the conversation when the character chose to continue" do
      replies = [structured_reply("確かめてくる", "continue", "CI を見る"), structured_reply("CI も通ったよ", "wait_for_user")]
      allow(runner).to receive(:run) { replies.shift }

      result = session.send_event("起きた理由: 反映した")

      expect(result[:response]).to eq("確かめてくる\n\nCI も通ったよ")
      expect(record.reload.messages.map { |m| m["content"] }).to eq(["確かめてくる", "CI も通ったよ"])
      expect(runner).to have_received(:run).with(hash_including(prompt: a_string_including("続けると決めた作業:\nCI を見る"))).once
    end

    it "lets claude -p errors through for the caller to handle" do
      allow(runner).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")

      expect { session.send_event("起きた理由: 反映した") }.to raise_error(ClaudeCli::Error)
      expect(record.reload.messages).to eq([])
    end
  end

  describe "turns of one character" do
    it "reads the conversation again after waiting for the other turn" do
      stale = described_class.new(character, record: ChatSessionRecord.find(record.id), llm_client: llm_client)
      ChatSessionRecord.find(record.id).append_message("model", "先に終わった報告")
      allow(runner).to receive(:run).and_return(structured_reply("続きだね", "wait_for_user"))

      stale.send_message("やあ")

      expect(runner).to have_received(:run).with(hash_including(prompt: a_string_including("アオイ: 先に終わった報告")))
    end

    it "waits until the other turn of the same character ends" do
      lock_path = Rails.root.join("tmp", "locks", "chat-#{character.id}.lock")
      FileUtils.mkdir_p(File.dirname(lock_path))
      allow(runner).to receive(:run).and_return(structured_reply("こんにちは", "wait_for_user"))
      order = []

      File.open(lock_path, File::RDWR | File::CREAT) do |other|
        other.flock(File::LOCK_EX)
        thread = Thread.new { session.send_message("やあ"); order << :answered }
        sleep 1
        order << :other_turn_ended
        other.flock(File::LOCK_UN)
        thread.join(5)
      end

      expect(order).to eq(%i[other_turn_ended answered])
    end
  end

  it "says it could not answer when claude -p fails, without falling back to Gemini" do
    allow(runner).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")
    allow(llm_client).to receive(:chat)

    result = session.send_message("やあ")

    expect(result[:response]).to eq("⚠️ memoria: claude -p が使えなかったので、返答できませんでした（usage limit reached）")
    expect(llm_client).not_to have_received(:chat)
    expect(record.reload.messages.map { |m| m["role"] }).to eq(["user"])
  end

  it "uses Gemini when the app layer injected its own tools" do
    allow(llm_client).to receive(:chat).and_return({ text: "Gemini", function_calls: [], usage: {} })
    allow(runner).to receive(:run)
    session = described_class.new(character, record: record, llm_client: llm_client,
      extra_tools: [{ functionDeclarations: [] }], extra_tool_executor: ->(*) { })

    expect(session.send_message("やあ")[:response]).to eq("Gemini")
    expect(runner).not_to have_received(:run)
  end

  it "uses Gemini when the backend is not configured" do
    ENV["MEMORIA_AGENT_BACKEND"] = nil
    allow(llm_client).to receive(:chat).and_return({ text: "Gemini", function_calls: [], usage: {} })

    expect(session.send_message("やあ")[:response]).to eq("Gemini")
    expect(session.tool_definitions.first[:functionDeclarations].map { |f| f[:name] }).not_to include("use_deep_model")
  end
end
