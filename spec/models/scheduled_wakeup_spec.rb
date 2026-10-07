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

  describe "recurrence" do
    it "accepts cron and adds the default time zone" do
      cron = described_class.parse_recurrence("0 7 * * *")
      expect(cron.original).to eq("0 7 * * * Asia/Tokyo")
    end

    it "accepts English natural language" do
      expect(described_class.parse_recurrence("every monday at 9:00")).to be_present
    end

    it "rejects unparseable recurrence" do
      w = build(:scheduled_wakeup, recurrence: "毎朝7時")
      expect(w).not_to be_valid
    end

    it "accepts proposed status" do
      w = build(:scheduled_wakeup, recurrence: "0 7 * * *", status: "proposed")
      expect(w).to be_valid
    end
  end

  describe "#advance!" do
    it "moves to the next occurrence and enqueues it" do
      travel_to Time.zone.parse("2026-10-07 07:00:30") do
        w = create(:scheduled_wakeup, recurrence: "0 7 * * * Asia/Tokyo",
          scheduled_at: Time.zone.parse("2026-10-07 07:00"))

        w.advance!

        expect(w.reload.scheduled_at).to eq(Time.zone.parse("2026-10-08 07:00"))
        expect(ThinkingLoopJob).to have_been_enqueued.with(w.character_id, w.id, w.scheduled_at.to_i)
      end
    end

    it "skips missed occurrences when woken up late" do
      travel_to Time.zone.parse("2026-10-10 09:00") do
        w = create(:scheduled_wakeup, recurrence: "0 7 * * * Asia/Tokyo",
          scheduled_at: Time.zone.parse("2026-10-07 07:00"))

        w.advance!

        expect(w.reload.scheduled_at).to eq(Time.zone.parse("2026-10-11 07:00"))
      end
    end
  end

  describe "#stale?" do
    let(:w) do
      build(:scheduled_wakeup, recurrence: "0 7 * * * Asia/Tokyo",
        scheduled_at: Time.zone.parse("2026-10-07 07:00"))
    end

    it "is false within the allowed lateness" do
      expect(w.stale?(Time.zone.parse("2026-10-07 09:59"))).to be false
    end

    it "is true when too late" do
      expect(w.stale?(Time.zone.parse("2026-10-07 10:01"))).to be true
    end

    it "is always false for one-shot wakeups" do
      one_shot = build(:scheduled_wakeup, scheduled_at: 1.day.ago)
      expect(one_shot.stale?).to be false
    end
  end

  describe "#notify_on_failure?" do
    it "is true for user-requested wakeups" do
      expect(build(:scheduled_wakeup, origin: "user").notify_on_failure?).to be true
    end

    it "is true for share wakeups" do
      expect(build(:scheduled_wakeup, origin: "self", action: "share").notify_on_failure?).to be true
    end

    it "is false for the character's own free wakeups" do
      expect(build(:scheduled_wakeup, origin: "self", action: "think").notify_on_failure?).to be false
    end
  end
end
