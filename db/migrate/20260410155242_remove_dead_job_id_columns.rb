class RemoveDeadJobIdColumns < ActiveRecord::Migration[8.1]
  def change
    # 旧 Sidekiq 時代の遺物。Phase 1 で書き込みも読み取りも消えた。
    # ジョブの早期 return ガード (ThinkingLoopJob#perform / ConversationTimeoutJob#perform)
    # で代替されている。
    remove_column :scheduled_wakeups, :sidekiq_job_id, :string
    remove_column :chat_sessions, :pending_timeout_job_id, :string
  end
end
