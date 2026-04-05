require "rails_helper"

RSpec.describe Thinking::SnapshotBuilder do
  let(:character) { create(:character) }
  let(:core) { instance_double(MemoriaCore::Core) }
  let(:health) { { sample_count: 0 } }

  before do
    allow(core).to receive(:last_user_conversation_age).and_return("30分前")
    allow(core).to receive(:last_user_conversation_topic).and_return("テスト")
    allow(core).to receive(:last_autonomous_log_summary).and_return(nil)
    allow(core).to receive(:pending_continuation).and_return(nil)
    allow(character).to receive(:scheduled_wakeups).and_return(ScheduledWakeup.none)
  end

  it "includes current time" do
    snapshot = described_class.build(core, character, health)
    expect(snapshot).to include("現在時刻:")
  end

  it "includes last conversation info" do
    snapshot = described_class.build(core, character, health)
    expect(snapshot).to include("30分前")
    expect(snapshot).to include("テスト")
  end

  it "includes continuation when present" do
    allow(core).to receive(:pending_continuation).and_return({
      topic: "作業の続き", items: ["確認する"]
    })

    snapshot = described_class.build(core, character, health)
    expect(snapshot).to include("作業の続き")
  end

  it "includes health warnings when sample count sufficient" do
    bad_health = { sample_count: 5, topic_diversity: 0.1, external_input_ratio: 0.1, max_continuation_chain: 5 }

    snapshot = described_class.build(core, character, bad_health)
    expect(snapshot).to include("同じトピック")
    expect(snapshot).to include("外部から")
    expect(snapshot).to include("連続")
  end

  it "includes upcoming schedules" do
    create(:scheduled_wakeup, character: character, scheduled_at: 1.hour.from_now, purpose: "リマインダー")

    # Re-allow with real association
    allow(character).to receive(:scheduled_wakeups).and_call_original

    snapshot = described_class.build(core, character, health)
    expect(snapshot).to include("リマインダー")
  end
end
