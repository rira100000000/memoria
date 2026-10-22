class ChatResult < ApplicationRecord
  belongs_to :user
  belongs_to :character

  validates :job_id, presence: true, uniqueness: true
  validates :message, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending processing completed failed] }

  scope :pending_or_processing, -> { where(status: %w[pending processing]) }

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
  end

  def complete!(response_text, usage_data)
    update!(
      status: "completed",
      response: response_text,
      usage: usage_data,
      completed_at: Time.current
    )
  end

  def fail!(error_msg)
    update!(
      status: "failed",
      error_message: error_msg,
      completed_at: Time.current
    )
  end
end
