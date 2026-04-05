FactoryBot.define do
  factory :channel_binding do
    character
    platform { "discord" }
    sequence(:channel_id) { |n| "10000000000000000#{n}" }
  end
end
