class PendingMessage < ApplicationRecord
  belongs_to :character
  belongs_to :user

  validates :trigger_type, presence: true, inclusion: { in: %w[thinking_loop sleep_phase] }
  validates :content, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending delivered read] }

  scope :unread, -> { where(status: %w[pending delivered]) }
  scope :for_user, ->(user) { where(user: user) }

  def deliver!
    update!(status: "delivered", delivered_at: Time.current)
  end

  def mark_read!
    update!(status: "read")
  end
end
