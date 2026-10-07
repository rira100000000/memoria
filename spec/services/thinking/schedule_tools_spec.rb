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
      result = described_class.add(character, time_text: "3時間後", purpose: "確認")

      expect(result[:success]).to be true
      expect(character.scheduled_wakeups.pending.count).to eq(1)
      expect(ThinkingLoopJob).to have_been_enqueued
    end

    it "rejects unparseable time" do
      result = described_class.add(character, time_text: "いつか", purpose: "test")
      expect(result[:error]).to be_present
    end

    it "clamps to minimum interval for autonomous" do
      described_class.add(character, time_text: "1分後", purpose: "急ぎ", autonomous: true)
      wakeup = character.scheduled_wakeups.last
      expect(wakeup.scheduled_at).to be > 9.minutes.from_now
    end

    it "allows short interval for user-initiated" do
      described_class.add(character, time_text: "2分後", purpose: "テスト")
      wakeup = character.scheduled_wakeups.last
      expect(wakeup.scheduled_at).to be < 5.minutes.from_now
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

  describe "recurring schedules" do
    it "creates an active recurring wakeup when the user asks" do
      result = described_class.add(character, time_text: nil, repeat: "0 7 * * *", purpose: "朝のまとめ", action: "share")

      expect(result[:success]).to be true
      wakeup = character.scheduled_wakeups.last
      expect(wakeup.status).to eq("pending")
      expect(wakeup.recurrence).to eq("0 7 * * * Asia/Tokyo")
      expect(wakeup.origin).to eq("user")
      expect(wakeup.remember).to be false
      expect(ThinkingLoopJob).to have_been_enqueued
    end

    it "makes the character's own recurring wakeups wait for approval" do
      allow(MessageDispatcher).to receive(:dispatch)

      result = described_class.add(character, time_text: nil, repeat: "0 22 * * *", purpose: "日記", autonomous: true)

      wakeup = character.scheduled_wakeups.last
      expect(wakeup.status).to eq("proposed")
      expect(result[:status]).to include("承認待ち")
      expect(ThinkingLoopJob).not_to have_been_enqueued
      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("提案"))
    end

    it "rejects intervals shorter than an hour" do
      result = described_class.add(character, time_text: nil, repeat: "*/10 * * * *", purpose: "連打")
      expect(result[:error]).to include("短すぎ")
    end

    it "rejects duplicates" do
      described_class.add(character, time_text: nil, repeat: "0 7 * * *", purpose: "朝")
      result = described_class.add(character, time_text: nil, repeat: "0 7 * * *", purpose: "朝2")
      expect(result[:error]).to include("既に")
    end

    it "does not block a one-shot wakeup near a recurring one" do
      travel_to Time.zone.parse("2026-10-07 20:00") do
        described_class.add(character, time_text: nil, repeat: "0 7 * * *", purpose: "朝のまとめ")
        result = described_class.add(character, time_text: "明日の朝", purpose: "挨拶")
        expect(result[:success]).to be true
      end
    end

    it "requires time or repeat" do
      result = described_class.add(character, time_text: nil, purpose: "なにか")
      expect(result[:error]).to be_present
    end
  end

  describe ".cancel with only_next" do
    it "skips just the next occurrence" do
      travel_to Time.zone.parse("2026-10-07 20:00") do
        described_class.add(character, time_text: nil, repeat: "0 7 * * *", purpose: "朝")
        wakeup = character.scheduled_wakeups.last

        result = described_class.cancel(character, wakeup.id, only_next: true)

        expect(result[:success]).to be true
        expect(wakeup.reload.status).to eq("pending")
        expect(wakeup.scheduled_at).to eq(Time.zone.parse("2026-10-09 07:00"))
      end
    end
  end

  describe ".approve" do
    it "activates a proposed wakeup" do
      wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 22 * * *", status: "proposed")

      result = described_class.execute("approve_schedule", { "schedule_id" => wakeup.id }, character: character)

      expect(result[:success]).to be true
      expect(wakeup.reload.status).to eq("pending")
      expect(ThinkingLoopJob).to have_been_enqueued
    end

    it "cannot be used autonomously" do
      wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 22 * * *", status: "proposed")

      result = described_class.execute("approve_schedule", { "schedule_id" => wakeup.id }, character: character, autonomous: true)

      expect(result[:error]).to be_present
      expect(wakeup.reload.status).to eq("proposed")
    end

    it "is not offered to the autonomous thinker" do
      names = described_class.definitions(autonomous: true)[:functionDeclarations].map { |f| f[:name] }
      expect(names).not_to include("approve_schedule")
    end
  end
end
