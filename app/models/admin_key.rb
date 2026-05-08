require "digest"
require "securerandom"

class AdminKey < ApplicationRecord
  validates :key_hash, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def self.issue!(label: nil)
    plain = "msak_#{SecureRandom.urlsafe_base64(32)}"
    create!(key_hash: hash_key(plain), label: label)
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
