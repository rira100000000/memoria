class CreateScheduledWakeups < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_wakeups do |t|
      t.references :character, null: false, foreign_key: true
      t.datetime :scheduled_at, null: false
      t.string :purpose, null: false            # なぜ起きるか（例: "マスターに挨拶", "作業リマインダー"）
      t.string :action                          # 何をするか（例: "share", "think", nil=自由）
      t.string :status, null: false, default: "pending"  # pending, executed, cancelled
      t.string :sidekiq_job_id

      t.timestamps
    end
    add_index :scheduled_wakeups, [:character_id, :status, :scheduled_at]

    # 不要になったカラムを削除
    remove_column :characters, :next_wakeup_at, :datetime
    remove_column :characters, :next_wakeup_job_id, :string
  end
end
