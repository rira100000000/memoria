require "rails_helper"

RSpec.describe PendingMessage, type: :model do
  describe "validations" do
    it "requires content" do
      msg = build(:pending_message, content: nil)
      expect(msg).not_to be_valid
    end

    it "requires valid trigger_type" do
      msg = build(:pending_message, trigger_type: "invalid")
      expect(msg).not_to be_valid
    end

    it "requires valid status" do
      msg = build(:pending_message, status: "invalid")
      expect(msg).not_to be_valid
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }

    it ".unread returns pending and delivered" do
      pending_msg = create(:pending_message, character: character, user: user, status: "pending")
      delivered_msg = create(:pending_message, character: character, user: user, status: "delivered")
      create(:pending_message, character: character, user: user, status: "read")

      expect(PendingMessage.unread).to contain_exactly(pending_msg, delivered_msg)
    end
  end

  describe "#mark_read!" do
    it "sets status to read" do
      msg = create(:pending_message)
      msg.mark_read!
      expect(msg.status).to eq("read")
    end
  end
end
