class ChannelBinding < ApplicationRecord
  belongs_to :character

  validates :platform, presence: true
  validates :channel_id, presence: true, uniqueness: { scope: :platform }

  scope :discord, -> { where(platform: "discord") }

  # purposes: キャラクターが自分から送るメッセージのうち、このチャンネルが受け持つ種類（"chat"、"dev" など、名前は自由）。
  # 予約された2つ:
  #   default: 送り先を指定しなかったもの、指定した種類を受け持つチャンネルがないもの
  #   system:  memoria からのお知らせ（予定の失敗、LLM が使えないなど）
  DEFAULT = "default".freeze
  SYSTEM = "system".freeze

  # @param to [String, nil] 送るメッセージの種類
  # @return [Array<ChannelBinding>] 送り先。どのチャンネルも受け持たないときは、結びつけたチャンネル全部
  def self.destinations(bindings, to)
    bindings = bindings.to_a
    [to.presence, DEFAULT].compact.each do |purpose|
      matched = bindings.select { |b| b.purposes.include?(purpose) }
      return matched if matched.any?
    end
    bindings
  end

  def self.find_character_for_discord(discord_channel_id)
    binding = discord.find_by(channel_id: discord_channel_id.to_s)
    binding&.character
  end
end
