require "rails_helper"

RSpec.describe ThinkingLoopWorker, type: :worker do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, thinking_loop_enabled: true) }

  it "is enqueued in the low queue" do
    expect(described_class.get_sidekiq_options["queue"].to_s).to eq("low")
  end

  describe "#perform" do
    it "skips when budget is exceeded" do
      allow(ApiBudget).to receive(:can_spend?).and_return(false)

      expect {
        described_class.new.perform(character.id)
      }.not_to raise_error

      expect(ApiBudget).to have_received(:can_spend?).with(user, "thinking_loop")
    end

    it "skips when no topics found by scanner" do
      allow(ApiBudget).to receive(:can_spend?).and_return(true)
      scanner = instance_double(MemoriaCore::TopicScanner, scan: [])
      allow(MemoriaCore::TopicScanner).to receive(:new).and_return(scanner)
      allow(MemoriaCore::VaultManager).to receive(:new).and_return(
        instance_double(MemoriaCore::VaultManager, ensure_structure!: nil)
      )

      described_class.new.perform(character.id)

      expect(PendingMessage.count).to eq(0)
    end
  end
end
