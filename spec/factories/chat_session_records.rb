FactoryBot.define do
  factory :chat_session_record do
    character
    user { character.user }
    status { "active" }
    messages { [] }
  end
end
