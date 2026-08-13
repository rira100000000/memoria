FactoryBot.define do
  factory :chat_result do
    user
    character
    job_id { SecureRandom.uuid }
    message { "Hello" }
    status { "pending" }
  end
end
