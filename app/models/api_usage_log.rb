class ApiUsageLog < ApplicationRecord
  belongs_to :user
  belongs_to :character, optional: true

  validates :trigger_type, presence: true,
    inclusion: { in: %w[user_message thinking_loop sleep_phase tag_profiling embedding] }
  validates :llm_model, presence: true

  scope :for_user, ->(user) { where(user: user) }
  scope :today, -> { where("created_at >= ?", Time.current.beginning_of_day) }
  scope :autonomous, -> { where(trigger_type: %w[thinking_loop sleep_phase]) }

  def self.record!(user:, trigger_type:, llm_model:, usage:, character: nil)
    create!(
      user: user,
      character: character,
      trigger_type: trigger_type,
      llm_model: llm_model,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      estimated_cost_usd: estimate_cost(llm_model, usage)
    )
  end

  # Gemini APIの概算コスト計算
  def self.estimate_cost(model_name, usage)
    input = usage[:input_tokens] || 0
    output = usage[:output_tokens] || 0

    # Gemini pricing (USD per 1M tokens, as of 2025)
    rates = cost_rates_for(model_name)
    (input * rates[:input] + output * rates[:output]) / 1_000_000.0
  end

  def self.cost_rates_for(model_name)
    case model_name
    when /flash-lite/
      { input: 0.075, output: 0.30 }
    when /flash/
      { input: 0.15, output: 0.60 }
    when /pro/
      { input: 1.25, output: 5.00 }
    else
      { input: 0.15, output: 0.60 } # default to flash rates
    end
  end
end
