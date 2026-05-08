require "digest"
require "securerandom"

class DeviceKey < ApplicationRecord
  belongs_to :device

  validates :key_hash, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # 平文キーを発行し、ハッシュをDBに保存して平文を返す（発行時の1回のみ）
  def self.issue!(device:, label: nil)
    plain = "msdk_#{SecureRandom.urlsafe_base64(32)}"
    create!(device: device, key_hash: hash_key(plain), label: label)
    plain
  end

  def self.find_by_plain_key(plain)
    return nil if plain.blank?
    active.find_by(key_hash: hash_key(plain))
  end

  def self.hash_key(plain)
    pepper = ENV.fetch("MS_KEY_PEPPER", "memoria-default-pepper-change-me")
    Digest::SHA256.hexdigest("#{plain}:#{pepper}")
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_used!
    update_column(:last_used_at, Time.current)
  end
end
