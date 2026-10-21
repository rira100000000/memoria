require "rails_helper"

RSpec.describe Thinking::Thinker, "with the claude -p backend" do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character, name: "アオイ") }
  let(:core) { MemoriaCore::Core.new(character.vault_path) }
  let(:llm_client) { instance_double(LlmClient, embedding_available?: false) }
  let(:runner) { instance_double(ClaudeCli::Runner) }
  let(:final_text) { "考えた。\n```json\n{\"summary\": \"ピコと話した\", \"share_message\": \"おはよう\"}\n```" }

  around do |example|
    original = ENV.to_h.slice("VAULT_ROOT", "MEMORIA_AGENT_BACKEND")
    ENV["VAULT_ROOT"] = vault_root
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"
    example.run
  ensure
    ENV["VAULT_ROOT"] = original["VAULT_ROOT"]
    ENV["MEMORIA_AGENT_BACKEND"] = original["MEMORIA_AGENT_BACKEND"]
    FileUtils.remove_entry(vault_root)
  end

  before do
    core.vault.ensure_structure!
    allow(ClaudeCli::Runner).to receive(:new).and_return(runner)
  end

  def think
    described_class.run(snapshot: "今の状況", character: character, core: core, health: {}, llm_client: llm_client)
  end

  it "thinks with claude -p and builds the same result as with Gemini" do
    # プラグインのツールは、会話ログに残す文（log）と話し相手（participant）を返せる
    events = [{ name: "talk_to_pet", args: { "message" => "おはよう" },
      result: { response: "ぴよ！", participant: "ピコ", log: ["アオイ → ピコ: おはよう", "ピコ: ぴよ！"] } }]
    allow(runner).to receive(:run).and_return(ClaudeCli::Runner::Result.new(text: final_text, tool_events: events, model: "sonnet"))

    result = think

    expect(result.summary).to eq("ピコと話した")
    expect(result.share_message).to eq("おはよう")
    expect(result.participants).to eq([:self, "ピコ"])
    expect(result.all_messages.map { |m| m[:content] }).to eq(["アオイ → ピコ: おはよう", "ピコ: ぴよ！", final_text])
    expect(result.to_conversation_text).to start_with("アオイ → ピコ: おはよう\n\nピコ: ぴよ！")
    expect(runner).to have_received(:run).with(hash_including(scene: :thinking, model: "sonnet", trigger_type: "thinking_loop",
      prompt: a_string_including("今の状況")))
  end

  it "recalls memories from the current situation, as in a chat" do
    retriever = instance_double(MemoriaCore::ContextRetriever)
    allow(MemoriaCore::EmbeddingStore).to receive(:new).and_return(instance_double(MemoriaCore::EmbeddingStore, initialize!: nil))
    allow(MemoriaCore::ContextRetriever).to receive(:new).and_return(retriever)
    allow(retriever).to receive(:retrieve).with("今の状況").and_return({ llm_context_prompt: "ピコと出会った日のこと" })
    allow(ProspectiveMemory).to receive(:scan).and_return("- 本を読む")
    allow(runner).to receive(:run).and_return(ClaudeCli::Runner::Result.new(text: final_text, tool_events: [], model: "sonnet"))

    think

    expect(runner).to have_received(:run).with(hash_including(
      system_prompt: a_string_including("ピコと出会った日のこと").and(a_string_including("- 本を読む"))))
  end

  it "still thinks when recalling memories fails" do
    allow(MemoriaCore::EmbeddingStore).to receive(:new).and_raise(RuntimeError, "no index")
    allow(runner).to receive(:run).and_return(ClaudeCli::Runner::Result.new(text: final_text, tool_events: [], model: "sonnet"))

    expect(think.summary).to eq("ピコと話した")
  end

  it "leaves web search to Claude Code instead of the Gemini tool" do
    names = described_class.tool_definitions(character).first[:functionDeclarations].map { |f| f[:name] }

    expect(names).not_to include("web_search")
  end

  it "raises when claude -p fails, without falling back to Gemini" do
    allow(runner).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")
    allow(llm_client).to receive(:chat)

    expect { think }.to raise_error(ClaudeCli::Error)
    expect(llm_client).not_to have_received(:chat)
  end
end
