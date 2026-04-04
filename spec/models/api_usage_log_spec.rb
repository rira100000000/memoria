require "rails_helper"

RSpec.describe ApiUsageLog, type: :model do
  describe "validations" do
    it "requires trigger_type" do
      log = build(:api_usage_log, trigger_type: nil)
      expect(log).not_to be_valid
    end

    it "requires valid trigger_type" do
      log = build(:api_usage_log, trigger_type: "invalid")
      expect(log).not_to be_valid
    end

    it "requires llm_model" do
      log = build(:api_usage_log, llm_model: nil)
      expect(log).not_to be_valid
    end
  end

  describe ".record!" do
    let(:user) { create(:user) }

    it "creates a log entry with cost estimation" do
      log = ApiUsageLog.record!(
        user: user,
        trigger_type: "user_message",
        llm_model: "gemini-2.5-flash",
        usage: { input_tokens: 1000, output_tokens: 500 }
      )

      expect(log).to be_persisted
      expect(log.input_tokens).to eq(1000)
      expect(log.output_tokens).to eq(500)
      expect(log.estimated_cost_usd).to be > 0
    end
  end

  describe ".estimate_cost" do
    it "calculates flash model costs" do
      cost = ApiUsageLog.estimate_cost("gemini-2.5-flash", { input_tokens: 1_000_000, output_tokens: 1_000_000 })
      expect(cost).to be_within(0.01).of(0.75) # 0.15 + 0.60
    end

    it "calculates flash-lite model costs" do
      cost = ApiUsageLog.estimate_cost("gemini-2.0-flash-lite", { input_tokens: 1_000_000, output_tokens: 1_000_000 })
      expect(cost).to be_within(0.01).of(0.375) # 0.075 + 0.30
    end

    it "calculates pro model costs" do
      cost = ApiUsageLog.estimate_cost("gemini-pro", { input_tokens: 1_000_000, output_tokens: 1_000_000 })
      expect(cost).to be_within(0.01).of(6.25) # 1.25 + 5.00
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    it ".today returns only today's logs" do
      create(:api_usage_log, user: user, created_at: 1.day.ago)
      today_log = create(:api_usage_log, user: user)

      expect(ApiUsageLog.for_user(user).today).to contain_exactly(today_log)
    end

    it ".autonomous returns only autonomous trigger types" do
      create(:api_usage_log, user: user, trigger_type: "user_message")
      auto_log = create(:api_usage_log, user: user, trigger_type: "thinking_loop")

      expect(ApiUsageLog.autonomous).to contain_exactly(auto_log)
    end
  end
end
