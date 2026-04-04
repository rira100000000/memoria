require "rails_helper"

RSpec.describe ChatResult, type: :model do
  describe "validations" do
    it "requires job_id" do
      cr = build(:chat_result, job_id: nil)
      expect(cr).not_to be_valid
    end

    it "requires unique job_id" do
      create(:chat_result, job_id: "abc-123")
      cr = build(:chat_result, job_id: "abc-123")
      expect(cr).not_to be_valid
    end

    it "requires message" do
      cr = build(:chat_result, message: nil)
      expect(cr).not_to be_valid
    end

    it "requires valid status" do
      cr = build(:chat_result, status: "invalid")
      expect(cr).not_to be_valid
    end

    %w[pending processing completed failed].each do |status|
      it "accepts status #{status}" do
        cr = build(:chat_result, status: status)
        expect(cr).to be_valid
      end
    end
  end

  describe "#complete!" do
    it "sets response, usage, status, and completed_at" do
      cr = create(:chat_result)
      cr.complete!("Hello!", { input_tokens: 10, output_tokens: 5 })

      expect(cr.status).to eq("completed")
      expect(cr.response).to eq("Hello!")
      expect(cr.usage).to eq({ "input_tokens" => 10, "output_tokens" => 5 })
      expect(cr.completed_at).to be_present
    end
  end

  describe "#fail!" do
    it "sets error_message, status, and completed_at" do
      cr = create(:chat_result)
      cr.fail!("Something went wrong")

      expect(cr.status).to eq("failed")
      expect(cr.error_message).to eq("Something went wrong")
      expect(cr.completed_at).to be_present
    end
  end
end
