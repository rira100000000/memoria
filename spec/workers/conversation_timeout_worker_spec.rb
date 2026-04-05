require "rails_helper"

RSpec.describe ConversationTimeoutWorker, type: :worker do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  it "is enqueued in the default queue" do
    expect(described_class.get_sidekiq_options["queue"].to_s).to eq("default")
  end

  describe "#perform" do
    it "skips when session no longer active" do
      record = create(:chat_session_record, character: character, user: user, status: "closed")

      expect {
        described_class.new.perform(record.id, 0)
      }.not_to raise_error
    end

    it "skips when message count changed (new messages arrived)" do
      record = create(:chat_session_record, character: character, user: user, status: "active",
        messages: [{ "role" => "user", "content" => "hello" }, { "role" => "model", "content" => "hi" }])

      # Expected count was 1 but now it's 2
      expect {
        described_class.new.perform(record.id, 1)
      }.not_to raise_error

      expect(record.reload.status).to eq("active")
    end
  end
end
