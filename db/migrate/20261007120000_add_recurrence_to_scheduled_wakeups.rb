class AddRecurrenceToScheduledWakeups < ActiveRecord::Migration[8.1]
  def change
    # 繰り返しのルール（cron式。例: "0 7 * * * Asia/Tokyo"）。nilなら単発
    add_column :scheduled_wakeups, :recurrence, :string
    # 実行結果を記憶（FL/SN）に残すか。毎日の定型タスクで記憶が埋まらないように切れる
    add_column :scheduled_wakeups, :remember, :boolean, null: false, default: true
    # 誰が入れた予定か（"user"=マスターに頼まれた, "self"=キャラが自分で入れた）
    add_column :scheduled_wakeups, :origin, :string, null: false, default: "self"
  end
end
