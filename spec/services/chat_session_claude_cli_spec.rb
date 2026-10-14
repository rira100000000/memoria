require "rails_helper"

RSpec.describe ChatSession, "with the claude -p backend" do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character, name: "ハル") }
  let(:record) { create(:chat_session_record, character: character) }
  let(:llm_client) { instance_double(LlmClient) }
  let(:session) { described_class.new(character, record: record, llm_client: llm_client, platform: :discord) }
  let(:runner) { instance_double(ClaudeCli::Runner) }

  def claude_result(text, events = [])
    ClaudeCli::Runner::Result.new(text: text, tool_events: events, model: "x")
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
      prompt: a_string_including("User: 前の話", "ハル: 前の返事", "Userの新しいメッセージ:\nやあ")
    ))
  end

  it "writes tool logs to the full log" do
    allow(runner).to receive(:run).and_return(claude_result("ok", [{ name: "talk_to_pet", args: {}, result: { log: ["ルル: ぴよ"] } }]))
    allow(session.chat_logger).to receive(:log_ai_message).and_call_original

    session.send_message("やあ")

    expect(session.chat_logger).to have_received(:log_ai_message).with("ルル: ぴよ")
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

  it "falls back to Gemini and says so when claude -p fails" do
    allow(runner).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")
    allow(llm_client).to receive(:chat).and_return({ text: "Geminiの返事", function_calls: [], usage: {} })

    result = session.send_message("やあ")

    expect(result[:response]).to eq("Geminiの返事\n\n⚠️ memoria: claude -p が使えなかったので Gemini で動きました（usage limit reached）")
    expect(record.reload.messages.last["content"]).to eq("Geminiの返事")
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
