require "rails_helper"

RSpec.describe ThinkingLoopSchedulerWorker, type: :worker do
  describe "#perform" do
    it "enqueues ThinkingLoopWorker for active characters" do
      char = create(:character, thinking_loop_enabled: true, thinking_loop_interval_minutes: 60)

      Sidekiq::Testing.fake! do
        described_class.new.perform
        expect(ThinkingLoopWorker.jobs.size).to eq(1)
        expect(ThinkingLoopWorker.jobs.first["args"]).to eq([char.id])
      end
    end

    it "skips characters with thinking_loop disabled" do
      create(:character, thinking_loop_enabled: false)

      Sidekiq::Testing.fake! do
        described_class.new.perform
        expect(ThinkingLoopWorker.jobs.size).to eq(0)
      end
    end

    it "skips characters that ran recently" do
      char = create(:character, thinking_loop_enabled: true, thinking_loop_interval_minutes: 60)
      create(:pending_message, character: char, user: char.user,
        trigger_type: "thinking_loop", created_at: 10.minutes.ago)

      Sidekiq::Testing.fake! do
        described_class.new.perform
        expect(ThinkingLoopWorker.jobs.size).to eq(0)
      end
    end

    it "runs if last message is older than interval" do
      char = create(:character, thinking_loop_enabled: true, thinking_loop_interval_minutes: 60)
      create(:pending_message, character: char, user: char.user,
        trigger_type: "thinking_loop", created_at: 2.hours.ago)

      Sidekiq::Testing.fake! do
        described_class.new.perform
        expect(ThinkingLoopWorker.jobs.size).to eq(1)
      end
    end
  end
end
