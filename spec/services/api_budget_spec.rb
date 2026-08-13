require "rails_helper"

RSpec.describe ApiBudget do
  let(:user) { create(:user) }

  describe ".can_spend?" do
    it "always allows user_message regardless of budget" do
      # Exhaust budget with autonomous actions
      create(:api_usage_log, user: user, trigger_type: "thinking_loop", estimated_cost_usd: 100)

      expect(ApiBudget.can_spend?(user, "user_message")).to be true
    end

    it "allows autonomous actions when under budget" do
      expect(ApiBudget.can_spend?(user, "thinking_loop")).to be true
    end

    it "denies autonomous actions when over budget" do
      create(:api_usage_log, user: user, trigger_type: "thinking_loop", estimated_cost_usd: 100)

      expect(ApiBudget.can_spend?(user, "sleep_phase")).to be false
    end

    it "only counts today's autonomous spend" do
      create(:api_usage_log, user: user, trigger_type: "thinking_loop",
        estimated_cost_usd: 100, created_at: 1.day.ago)

      expect(ApiBudget.can_spend?(user, "thinking_loop")).to be true
    end
  end

  describe ".today_summary" do
    it "returns usage summary" do
      create(:api_usage_log, user: user, trigger_type: "user_message",
        total_tokens: 1000, estimated_cost_usd: 0.001)
      create(:api_usage_log, user: user, trigger_type: "thinking_loop",
        total_tokens: 500, estimated_cost_usd: 0.0005)

      summary = ApiBudget.today_summary(user)

      expect(summary[:request_count]).to eq(2)
      expect(summary[:total_tokens]).to eq(1500)
      expect(summary[:autonomous_cost_usd]).to be > 0
      expect(summary[:daily_budget_usd]).to be > 0
    end
  end
end
