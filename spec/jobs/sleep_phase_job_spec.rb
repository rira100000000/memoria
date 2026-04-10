require "rails_helper"

RSpec.describe SleepPhaseJob, type: :job do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  it "is enqueued in the low queue" do
    expect(described_class.new.queue_name).to eq("low")
  end

  describe "#perform" do
    it "skips when budget is exceeded" do
      allow(ApiBudget).to receive(:can_spend?).and_return(false)

      expect {
        described_class.new.perform(character.id, "FullLog/test.md")
      }.not_to raise_error

      expect(ApiBudget).to have_received(:can_spend?).with(user, "sleep_phase")
    end
  end
end
