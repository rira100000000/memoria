class ScheduledWakeup < ApplicationRecord
  belongs_to :character

  validates :scheduled_at, presence: true
  validates :purpose, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending executed cancelled] }

  scope :pending, -> { where(status: "pending") }
  scope :upcoming, -> { pending.where("scheduled_at > ?", Time.current).order(:scheduled_at) }
  scope :due, -> { pending.where("scheduled_at <= ?", Time.current) }

  def execute!
    update!(status: "executed")
  end

  def cancel!
    update!(status: "cancelled")
    # Sidekiqジョブもキャンセル（スケジュール済みセットから削除）
    if sidekiq_job_id.present?
      require "sidekiq/api"
      Sidekiq::ScheduledSet.new.select { |job| job.jid == sidekiq_job_id }.each(&:delete)
    end
  end
end
