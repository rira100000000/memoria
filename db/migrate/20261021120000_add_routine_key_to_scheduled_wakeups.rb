class AddRoutineKeyToScheduledWakeups < ActiveRecord::Migration[8.1]
  def change
    # プラグインが宣言した定期の起床の名前（MemoriaServer::Plugin#routines の key）。
    # 宣言の中身が変わっても同じ予定を更新するための目印。nilならプラグインと関係のない予定
    add_column :scheduled_wakeups, :routine_key, :string
    add_index :scheduled_wakeups, [:character_id, :routine_key], unique: true, where: "routine_key IS NOT NULL"
  end
end
