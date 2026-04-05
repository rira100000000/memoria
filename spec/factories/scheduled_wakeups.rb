FactoryBot.define do
  factory :scheduled_wakeup do
    character
    scheduled_at { 1.hour.from_now }
    purpose { "テスト起床" }
    status { "pending" }
  end
end
