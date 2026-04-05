require "rails_helper"

RSpec.describe ScheduledWakeup, type: :model do
  describe "validations" do
    it "requires scheduled_at" do
      w = build(:scheduled_wakeup, scheduled_at: nil)
      expect(w).not_to be_valid
    end

    it "requires purpose" do
      w = build(:scheduled_wakeup, purpose: nil)
      expect(w).not_to be_valid
    end

    it "requires valid status" do
      w = build(:scheduled_wakeup, status: "invalid")
      expect(w).not_to be_valid
    end
  end

  describe "scopes" do
    it ".pending returns only pending" do
      pending_w = create(:scheduled_wakeup, status: "pending")
      create(:scheduled_wakeup, status: "executed")
      create(:scheduled_wakeup, status: "cancelled")

      expect(ScheduledWakeup.pending).to contain_exactly(pending_w)
    end

    it ".upcoming returns future pending sorted by time" do
      far = create(:scheduled_wakeup, scheduled_at: 3.hours.from_now)
      near = create(:scheduled_wakeup, scheduled_at: 1.hour.from_now)
      create(:scheduled_wakeup, scheduled_at: 1.hour.ago)

      expect(ScheduledWakeup.upcoming).to eq([near, far])
    end
  end

  describe "#execute!" do
    it "sets status to executed" do
      w = create(:scheduled_wakeup)
      w.execute!
      expect(w.status).to eq("executed")
    end
  end

  describe "#cancel!" do
    it "sets status to cancelled" do
      w = create(:scheduled_wakeup)
      w.cancel!
      expect(w.status).to eq("cancelled")
    end
  end
end
