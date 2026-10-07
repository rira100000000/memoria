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

  describe "wakeups" do
    let(:result) do
      Thinking::ThinkingResult.new(all_messages: [], summary: "まとめた", share_message: nil, participants: [:self])
    end

    before do
      allow(MemoriaCore::Core).to receive(:new).and_return(instance_double(MemoriaCore::Core))
      allow(Thinking::ThoughtHealthMonitor).to receive(:report).and_return({})
      allow(Thinking::SnapshotBuilder).to receive(:build).and_return("snapshot")
      allow(Thinking::Thinker).to receive(:run).and_return(result)
      allow(MessageDispatcher).to receive(:dispatch)
      allow(ApiBudget).to receive(:can_spend?).and_return(true)
      allow_any_instance_of(described_class).to receive(:sleep)
      allow_any_instance_of(described_class).to receive(:save_as_memory)
    end

    it "ignores a stale job after the wakeup was moved" do
      wakeup = create(:scheduled_wakeup, character: character)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i - 60)

      expect(Thinking::Thinker).not_to have_received(:run)
      expect(wakeup.reload.status).to eq("pending")
    end

    it "always delivers share wakeups even without a share message" do
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, "まとめた")
    end

    it "saves memory by default" do
      wakeup = create(:scheduled_wakeup, character: character, scheduled_at: Time.current)
      job = described_class.new
      allow(job).to receive(:save_as_memory)

      job.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(job).to have_received(:save_as_memory)
    end

    it "skips memory when remember is false" do
      wakeup = create(:scheduled_wakeup, character: character, remember: false, scheduled_at: Time.current)
      job = described_class.new
      allow(job).to receive(:save_as_memory)

      job.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(job).not_to have_received(:save_as_memory)
    end

    it "notifies when the budget is exceeded for a user-requested wakeup" do
      allow(ApiBudget).to receive(:can_spend?).and_return(false)
      wakeup = create(:scheduled_wakeup, character: character, origin: "user", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("予算"))
    end

    it "retries once, then notifies instead of failing silently" do
      allow(Thinking::Thinker).to receive(:run).and_raise(RuntimeError, "boom")
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      expect {
        described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)
      }.not_to raise_error

      expect(Thinking::Thinker).to have_received(:run).twice
      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("エラー"))
    end

    describe "recurring" do
      it "schedules the next occurrence before running" do
        travel_to Time.zone.parse("2026-10-07 07:00:10") do
          wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 7 * * * Asia/Tokyo",
            scheduled_at: Time.zone.parse("2026-10-07 07:00"))
          allow(Thinking::Thinker).to receive(:run).and_raise(RuntimeError, "boom")

          described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

          expect(wakeup.reload.status).to eq("pending")
          expect(wakeup.scheduled_at).to eq(Time.zone.parse("2026-10-08 07:00"))
          expect(ThinkingLoopJob).to have_been_enqueued.with(character.id, wakeup.id, wakeup.scheduled_at.to_i)
        end
      end

      it "skips a stale occurrence and says so" do
        travel_to Time.zone.parse("2026-10-07 15:00") do
          wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 7 * * * Asia/Tokyo",
            action: "share", scheduled_at: Time.zone.parse("2026-10-07 07:00"))

          described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

          expect(Thinking::Thinker).not_to have_received(:run)
          expect(MessageDispatcher).to have_received(:dispatch).with(character, include("飛ばしました"))
          expect(wakeup.reload.scheduled_at).to eq(Time.zone.parse("2026-10-08 07:00"))
        end
      end

      it "does not run proposed wakeups" do
        wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 7 * * *", status: "proposed")

        described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

        expect(Thinking::Thinker).not_to have_received(:run)
      end
    end
  end
end
