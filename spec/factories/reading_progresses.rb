FactoryBot.define do
  factory :reading_progress do
    character
    sequence(:work_id) { |n| "#{n}" }
    title { "走れメロス" }
    author { "太宰治" }
    source_info { "底本: 太宰治全集" }
    current_position { 0 }
    total_length { 10000 }
    status { "reading" }
  end
end
