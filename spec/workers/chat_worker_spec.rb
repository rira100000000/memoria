require "rails_helper"

RSpec.describe ChatWorker, type: :worker do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:chat_result) { create(:chat_result, user: user, character: character) }

  it "is enqueued in the default queue" do
    expect(described_class.get_sidekiq_options["queue"].to_s).to eq("default")
  end

  describe "#perform" do
    let(:mock_session) do
      instance_double(ChatSession, send_message: {
        response: "Answer",
        usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
      })
    end

    before do
      allow(ChatSession).to receive(:new).and_return(mock_session)
    end

    it "completes the chat result on success" do
      described_class.new.perform(chat_result.id)

      chat_result.reload
      expect(chat_result.status).to eq("completed")
      expect(chat_result.response).to eq("Answer")
    end

    it "fails the chat result on error" do
      allow(mock_session).to receive(:send_message).and_raise("LLM error")

      described_class.new.perform(chat_result.id)

      chat_result.reload
      expect(chat_result.status).to eq("failed")
      expect(chat_result.error_message).to eq("LLM error")
    end
  end
end
