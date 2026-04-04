require "rails_helper"

RSpec.describe MessageDispatcher do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:dispatcher) { described_class.new(character) }

  describe "#dispatch" do
    it "creates a pending message" do
      expect {
        dispatcher.dispatch("Hello!", trigger_type: "thinking_loop", topic_tag: "test")
      }.to change(PendingMessage, :count).by(1)

      msg = PendingMessage.last
      expect(msg.content).to eq("Hello!")
      expect(msg.trigger_type).to eq("thinking_loop")
      expect(msg.topic_tag).to eq("test")
      expect(msg.status).to eq("pending")
      expect(msg.character).to eq(character)
      expect(msg.user).to eq(user)
    end
  end
end
