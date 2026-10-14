require "rails_helper"

RSpec.describe Thinking::Thinker, "with the claude -p backend" do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character, name: "ハル", pet_config: { "name" => "ルル", "appearance" => "青い鳥" }) }
  let(:core) { MemoriaCore::Core.new(character.vault_path) }
  let(:llm_client) { instance_double(LlmClient) }
  let(:runner) { instance_double(ClaudeCli::Runner) }
  let(:final_text) { "考えた。\n```json\n{\"summary\": \"ルルと話した\", \"share_message\": \"おはよう\"}\n```" }

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
    allow(MessageDispatcher).to receive(:dispatch)
    ClaudeCli.reset_fallback_notices!
  end

  def think
    described_class.run(snapshot: "今の状況", character: character, core: core, health: {}, llm_client: llm_client)
  end

  it "thinks with claude -p and builds the same result as with Gemini" do
    events = [{ name: "talk_to_pet", args: { "message" => "おはよう" }, result: { response: "ぴよ！" } }]
    allow(runner).to receive(:run).and_return(ClaudeCli::Runner::Result.new(text: final_text, tool_events: events, model: "sonnet"))

    result = think

    expect(result.summary).to eq("ルルと話した")
    expect(result.share_message).to eq("おはよう")
    expect(result.participants).to eq([:self, :pet])
    expect(result.all_messages.map { |m| m[:content] }).to eq(["おはよう", "ぴよ！", final_text])
    expect(runner).to have_received(:run).with(hash_including(scene: :thinking, model: "sonnet", trigger_type: "thinking_loop",
      prompt: a_string_including("今の状況")))
  end

  it "falls back to Gemini and notifies once per hour when claude -p fails" do
    allow(runner).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")
    allow(llm_client).to receive(:chat).and_return({ text: final_text, function_calls: [], usage: {} })

    2.times { expect(think.summary).to eq("ルルと話した") }

    expect(MessageDispatcher).to have_received(:dispatch).once
      .with(character, a_string_including("Gemini で動きました（usage limit reached）"))
  end
end
