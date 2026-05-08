class Presence < ApplicationRecord
  belongs_to :character
  belongs_to :active_device, class_name: "Device", optional: true

  validates :character_id, uniqueness: true

  def absent?
    active_device_id.nil?
  end

  def assign_to!(device, since: Time.current)
    update!(active_device: device, since: since)
  end

  def release!
    update!(active_device: nil, since: nil)
  end
end
