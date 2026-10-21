require "rails_helper"

RSpec.describe ThinkingLoopJob, type: :job do
  let(:character) { create(:character, thinking_loop_enabled: true) }
  let(:adapter) { instance_double(MemoriaServer::Adapter, wake: { share_message: nil, summary: "まとめた" }, record_outgoing: nil) }

  before do
    allow(MemoriaServer).to receive(:adapter).and_return(adapter)
    allow(MessageDispatcher).to receive(:dispatch)
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  it "is enqueued in the low queue" do
    expect(described_class.new.queue_name).to eq("low")
  end

  describe "free thinking" do
    it "wakes the character through the adapter" do
      described_class.new.perform(character.id)

      expect(adapter).to have_received(:wake).with(character_id: character.id, wakeup: nil)
    end

    it "skips when thinking_loop disabled" do
      character.update!(thinking_loop_enabled: false)

      described_class.new.perform(character.id)

      expect(adapter).not_to have_received(:wake)
    end

    it "ends quietly when the adapter did not wake" do
      allow(adapter).to receive(:wake).and_raise(MemoriaServer::WakeSkipped, "予算切れ")

      expect { described_class.new.perform(character.id) }.not_to raise_error
      expect(MessageDispatcher).not_to have_received(:dispatch)
    end

    it "sends what the character wants to share" do
      allow(adapter).to receive(:wake).and_return({ share_message: "おはよう", summary: "挨拶した" })

      described_class.new.perform(character.id)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, "おはよう")
    end
  end

  describe "wakeups" do
    it "passes the wakeup to the adapter" do
      wakeup = create(:scheduled_wakeup, character: character, purpose: "朝の挨拶", action: "share",
        remember: false, scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(adapter).to have_received(:wake).with(character_id: character.id, wakeup: {
        purpose: "朝の挨拶", action: "share", recurrence: nil, due_at: wakeup.scheduled_at, remember: false,
      })
    end

    it "skips cancelled wakeups" do
      wakeup = create(:scheduled_wakeup, character: character, status: "cancelled")

      described_class.new.perform(character.id, wakeup.id)

      expect(adapter).not_to have_received(:wake)
    end

    it "marks wakeup as executed" do
      wakeup = create(:scheduled_wakeup, character: character, status: "pending")

      described_class.new.perform(character.id, wakeup.id)

      expect(wakeup.reload.status).to eq("executed")
    end

    it "ignores a stale job after the wakeup was moved" do
      wakeup = create(:scheduled_wakeup, character: character)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i - 60)

      expect(adapter).not_to have_received(:wake)
      expect(wakeup.reload.status).to eq("pending")
    end

    it "always delivers share wakeups even without a share message" do
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, "まとめた")
    end

    it "adds the delivered message to the chat so that a reply continues it" do
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(adapter).to have_received(:record_outgoing).with(character_id: character.id, text: "まとめた")
    end

    it "still finishes the wakeup when the message cannot be added to the chat" do
      allow(adapter).to receive(:record_outgoing).and_raise("db locked")
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, "まとめた")
      expect(wakeup.reload.status).to eq("executed")
    end

    it "notifies without retrying when the adapter did not wake a user-requested wakeup" do
      allow(adapter).to receive(:wake).and_raise(MemoriaServer::WakeSkipped, "今日のAPI予算を使い切っていたため、動けませんでした。")
      wakeup = create(:scheduled_wakeup, character: character, origin: "user", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(adapter).to have_received(:wake).once
      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("予算"))
    end

    it "retries once, then notifies instead of failing silently" do
      allow(adapter).to receive(:wake).and_raise(RuntimeError, "boom")
      wakeup = create(:scheduled_wakeup, character: character, action: "share", scheduled_at: Time.current)

      expect {
        described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)
      }.not_to raise_error

      expect(adapter).to have_received(:wake).twice
      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("エラー"))
    end

    it "notifies when the adapter does not support waking" do
      allow(MemoriaServer).to receive(:adapter).and_return(MemoriaServer::Adapter.new)
      wakeup = create(:scheduled_wakeup, character: character, origin: "user", scheduled_at: Time.current)

      described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

      expect(MessageDispatcher).to have_received(:dispatch).with(character, include("起床に対応していません"))
    end

    describe "recurring" do
      it "schedules the next occurrence before running" do
        travel_to Time.zone.parse("2026-10-07 07:00:10") do
          wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 7 * * * Asia/Tokyo",
            scheduled_at: Time.zone.parse("2026-10-07 07:00"))
          allow(adapter).to receive(:wake).and_raise(RuntimeError, "boom")

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

          expect(adapter).not_to have_received(:wake)
          expect(MessageDispatcher).to have_received(:dispatch).with(character, include("飛ばしました"))
          expect(wakeup.reload.scheduled_at).to eq(Time.zone.parse("2026-10-08 07:00"))
        end
      end

      it "does not run proposed wakeups" do
        wakeup = create(:scheduled_wakeup, character: character, recurrence: "0 7 * * *", status: "proposed")

        described_class.new.perform(character.id, wakeup.id, wakeup.scheduled_at.to_i)

        expect(adapter).not_to have_received(:wake)
      end
    end
  end
end
