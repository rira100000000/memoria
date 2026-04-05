require_relative "../config/environment"

# テストキャラクターで記憶整理を試す
character = Character.find(3)  # テストキャラクター
puts "Character: #{character.name} (ID: #{character.id})"

# 記憶整理用のスケジュールを作って即実行
wakeup = character.scheduled_wakeups.create!(
  scheduled_at: Time.current,
  purpose: "今日の記憶を振り返って整理する。不要な記憶は統合またはアーカイブする。",
  status: "pending"
)

worker = ThinkingLoopWorker.new
worker.perform(character.id, wakeup.id)

puts "Done!"
