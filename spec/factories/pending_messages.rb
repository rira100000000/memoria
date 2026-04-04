FactoryBot.define do
  factory :pending_message do
    character
    user { character.user }
    trigger_type { "thinking_loop" }
    content { "Hey, I was thinking about something..." }
    status { "pending" }
  end
end
