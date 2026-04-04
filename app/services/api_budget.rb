# 日次APIバジェットの管理
# user_messageはバジェット制限対象外、自発的行動のみ制限
class ApiBudget
  # デフォルトの日次バジェット（USD）
  DEFAULT_DAILY_BUDGET = ENV.fetch("DAILY_API_BUDGET_USD", "1.0").to_f

  class << self
    # 指定のtrigger_typeで支出可能か判定
    # user_messageは常にtrue（制限対象外）
    def can_spend?(user, trigger_type)
      return true if trigger_type == "user_message"

      today_spend = ApiUsageLog.for_user(user).today.autonomous.sum(:estimated_cost_usd)
      today_spend < daily_budget(user)
    end

    # 今日の使用状況サマリ
    def today_summary(user)
      logs = ApiUsageLog.for_user(user).today
      {
        total_cost_usd: logs.sum(:estimated_cost_usd).to_f,
        autonomous_cost_usd: logs.autonomous.sum(:estimated_cost_usd).to_f,
        total_tokens: logs.sum(:total_tokens),
        request_count: logs.count,
        daily_budget_usd: daily_budget(user),
        budget_remaining_usd: [daily_budget(user) - logs.autonomous.sum(:estimated_cost_usd).to_f, 0].max,
      }
    end

    private

    def daily_budget(user)
      # 将来的にはユーザーごとの設定を参照
      DEFAULT_DAILY_BUDGET
    end
  end
end
