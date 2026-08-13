class ChannelBinding < ApplicationRecord
  belongs_to :character

  validates :platform, presence: true
  validates :channel_id, presence: true, uniqueness: { scope: :platform }

  scope :discord, -> { where(platform: "discord") }

  def self.find_character_for_discord(discord_channel_id)
    binding = discord.find_by(channel_id: discord_channel_id.to_s)
    binding&.character
  end
end
