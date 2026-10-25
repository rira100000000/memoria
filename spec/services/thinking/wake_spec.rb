require "rails_helper"

RSpec.describe Thinking::Wake do
  let(:character) { create(:character, thinking_loop_enabled: true) }
  let(:result) do
    Thinking::ThinkingResult.new(all_messages: [], summary: "まとめた", share_message: "おはよう", participants: [:self])
  end

  before do
    allow(MemoriaCore::Core).to receive(:new).and_return(instance_double(MemoriaCore::Core))
    allow(Thinking::ThoughtHealthMonitor).to receive(:report).and_return({})
    allow(Thinking::SnapshotBuilder).to receive(:build).and_return("snapshot")
    allow(Thinking::Thinker).to receive(:run).and_return(result)
    allow(ApiBudget).to receive(:can_spend?).and_return(true)
    allow(MessageDispatcher).to receive(:dispatch)
    allow_any_instance_of(described_class).to receive(:save_as_memory)
  end

  def wakeup(**overrides)
    { purpose: "朝の挨拶", action: nil, recurrence: nil, due_at: Time.current, remember: true }.merge(overrides)
  end

  it "returns what the character wants to share and a summary" do
    expect(described_class.run(character)).to eq({ share_message: "おはよう", summary: "まとめた" })
  end

  it "tells the character why it woke up" do
    described_class.run(character, wakeup: wakeup(action: "share", recurrence: "0 7 * * *"))

    expect(Thinking::Thinker).to have_received(:run).with(hash_including(
      snapshot: a_string_including("今回起きた理由: 朝の挨拶").and(a_string_including("必ず伝える")).and(a_string_including("繰り返しの予定"))))
  end

  it "tells the thinker which wakeup it is, for the tool usage log" do
    described_class.run(character, wakeup: wakeup(id: 12))

    expect(Thinking::Thinker).to have_received(:run).with(hash_including(usage_context: { wakeup_id: 12, purpose: "朝の挨拶" }))
  end

  it "has no usage context without a wakeup" do
    described_class.run(character)

    expect(Thinking::Thinker).to have_received(:run).with(hash_including(usage_context: nil))
  end

  it "tells the character when it woke up late" do
    described_class.run(character, wakeup: wakeup(due_at: 20.minutes.ago))

    expect(Thinking::Thinker).to have_received(:run).with(hash_including(snapshot: a_string_including("20分遅れて")))
  end

  it "does not wake when the budget is exceeded" do
    allow(ApiBudget).to receive(:can_spend?).and_return(false)

    expect { described_class.run(character) }.to raise_error(MemoriaServer::WakeSkipped, include("予算"))
    expect(ApiBudget).to have_received(:can_spend?).with(character.user, "thinking_loop")
    expect(Thinking::Thinker).not_to have_received(:run)
  end

  it "saves memory by default" do
    wake = described_class.new(character, wakeup)
    allow(wake).to receive(:save_as_memory)

    wake.run

    expect(wake).to have_received(:save_as_memory)
  end

  it "skips memory when remember is false" do
    wake = described_class.new(character, wakeup(remember: false))
    allow(wake).to receive(:save_as_memory)

    wake.run

    expect(wake).not_to have_received(:save_as_memory)
  end

  it "tells the master once and skips when claude -p is unavailable in free thinking" do
    ClaudeCli.reset_failure_notices!
    allow(Thinking::Thinker).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")

    2.times { expect { described_class.run(character) }.to raise_error(MemoriaServer::WakeSkipped) }

    expect(MessageDispatcher).to have_received(:dispatch).once
      .with(character, "⚠️ memoria: claude -p が使えなかったので、思考ループを実行できませんでした（usage limit reached）", to: "system")
  end

  it "leaves the notice to the wakeup when claude -p is unavailable for a wakeup" do
    allow(Thinking::Thinker).to receive(:run).and_raise(ClaudeCli::Error, "usage limit reached")

    expect { described_class.run(character, wakeup: wakeup) }.to raise_error(MemoriaServer::WakeSkipped, include("usage limit reached"))
    expect(MessageDispatcher).not_to have_received(:dispatch)
  end
end
