require "rails_helper"

RSpec.describe Thinking::ScheduleTools do
  let(:character) { create(:character, thinking_loop_enabled: true) }

  describe ".list" do
    it "returns empty message when no schedules" do
      result = described_class.list(character)
      expect(result[:schedules]).to eq("予定はありません")
    end

    it "lists upcoming schedules" do
      create(:scheduled_wakeup, character: character, scheduled_at: 1.hour.from_now, purpose: "テスト")

      result = described_class.list(character)
      expect(result[:schedules]).to include("テスト")
    end
  end

  describe ".add" do
    it "creates a scheduled wakeup" do
      Sidekiq::Testing.fake! do
        result = described_class.add(character, time_text: "3時間後", purpose: "確認")

        expect(result[:success]).to be true
        expect(character.scheduled_wakeups.pending.count).to eq(1)
        expect(ThinkingLoopWorker.jobs.size).to eq(1)
      end
    end

    it "rejects unparseable time" do
      result = described_class.add(character, time_text: "いつか", purpose: "test")
      expect(result[:error]).to be_present
    end

    it "clamps to minimum interval for autonomous" do
      Sidekiq::Testing.fake! do
        result = described_class.add(character, time_text: "1分後", purpose: "急ぎ", autonomous: true)
        wakeup = character.scheduled_wakeups.last
        expect(wakeup.scheduled_at).to be > 9.minutes.from_now
      end
    end

    it "allows short interval for user-initiated" do
      Sidekiq::Testing.fake! do
        result = described_class.add(character, time_text: "2分後", purpose: "テスト")
        wakeup = character.scheduled_wakeups.last
        expect(wakeup.scheduled_at).to be < 5.minutes.from_now
      end
    end
  end

  describe ".cancel" do
    it "cancels a pending schedule" do
      wakeup = create(:scheduled_wakeup, character: character)

      result = described_class.cancel(character, wakeup.id)
      expect(result[:success]).to be true
      expect(wakeup.reload.status).to eq("cancelled")
    end

    it "returns error for unknown id" do
      result = described_class.cancel(character, 99999)
      expect(result[:error]).to be_present
    end
  end
end
