require "rails_helper"

RSpec.describe ChatSessionRecord, type: :model do
  describe "validations" do
    it "requires valid status" do
      record = build(:chat_session_record, status: "invalid")
      expect(record).not_to be_valid
    end

    %w[active closed].each do |status|
      it "accepts status #{status}" do
        record = build(:chat_session_record, status: status)
        expect(record).to be_valid
      end
    end
  end

  describe "#append_message" do
    it "adds a message and updates last_message_at" do
      record = create(:chat_session_record)
      record.append_message("user", "Hello")

      expect(record.messages.length).to eq(1)
      expect(record.messages.first).to eq({ "role" => "user", "content" => "Hello" })
      expect(record.last_message_at).to be_present
    end
  end

  describe "#close!" do
    it "sets status to closed" do
      record = create(:chat_session_record)
      record.close!
      expect(record.status).to eq("closed")
    end
  end

  describe "scopes" do
    it ".active returns only active sessions" do
      active = create(:chat_session_record, status: "active")
      create(:chat_session_record, status: "closed")

      expect(ChatSessionRecord.active).to contain_exactly(active)
    end
  end

  describe "#message_count" do
    it "returns the number of messages" do
      record = create(:chat_session_record, messages: [
        { "role" => "user", "content" => "Hi" },
        { "role" => "model", "content" => "Hello" },
      ])
      expect(record.message_count).to eq(2)
    end
  end
end
