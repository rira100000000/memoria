FactoryBot.define do
  factory :character do
    user
    sequence(:name) { |n| "Character#{n}" }
    system_prompt { "You are a helpful assistant." }
  end
end
