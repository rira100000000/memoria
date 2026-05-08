class Transfer < ApplicationRecord
  belongs_to :character
  belongs_to :from_device, class_name: "Device", optional: true
  belongs_to :to_device, class_name: "Device"

  validates :occurred_at, presence: true

  scope :recent, -> { order(occurred_at: :desc) }

  def self.record!(character:, from_device:, to_device:, reason:, at: Time.current)
    create!(
      character: character,
      from_device: from_device,
      to_device: to_device,
      reason: reason,
      occurred_at: at,
    )
  end
end
