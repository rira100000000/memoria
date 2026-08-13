FactoryBot.define do
  factory :api_usage_log do
    user
    trigger_type { "user_message" }
    llm_model { "gemini-2.5-flash" }
    input_tokens { 100 }
    output_tokens { 50 }
    total_tokens { 150 }
    estimated_cost_usd { 0.000045 }
  end
end
