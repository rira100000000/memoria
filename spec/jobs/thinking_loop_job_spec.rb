require "rails_helper"

RSpec.describe ThinkingLoopJob, type: :job do
  let(:character) { create(:character, thinking_loop_enabled: true) }

  it "is enqueued in the low queue" do
    expect(described_class.new.queue_name).to eq("low")
  end

  describe "#perform" do
    it "skips when thinking_loop disabled" do
      character.update!(thinking_loop_enabled: false)
      allow(MemoriaCore::Core).to receive(:new)

      described_class.new.perform(character.id)

      expect(MemoriaCore::Core).not_to have_received(:new)
    end

    it "skips when budget exceeded" do
      allow(ApiBudget).to receive(:can_spend?).and_return(false)
      allow(MemoriaCore::Core).to receive(:new).and_return(
        instance_double(MemoriaCore::Core)
      )

      described_class.new.perform(character.id)

      expect(ApiBudget).to have_received(:can_spend?).with(character.user, "thinking_loop")
    end

    it "skips cancelled wakeups" do
      wakeup = create(:scheduled_wakeup, character: character, status: "cancelled")

      allow(MemoriaCore::Core).to receive(:new)
      described_class.new.perform(character.id, wakeup.id)

      expect(MemoriaCore::Core).not_to have_received(:new)
    end

    it "marks wakeup as executed" do
      wakeup = create(:scheduled_wakeup, character: character, status: "pending")

      allow(ApiBudget).to receive(:can_spend?).and_return(false)

      described_class.new.perform(character.id, wakeup.id)

      expect(wakeup.reload.status).to eq("executed")
    end
  end
end
