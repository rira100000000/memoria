require "net/http"
require "json"
require "uri"

# キャラクターからのメッセージを外部チャネルに送信する
class MessageDispatcher
  DISCORD_API_BASE = "https://discord.com/api/v10"

  def self.dispatch(character, message)
    return if message.blank?

    character.channel_bindings.discord.each do |binding|
      send_to_discord(binding.channel_id, message)
    end
  end

  def self.send_to_discord(channel_id, message)
    token = ENV["DISCORD_BOT_TOKEN"]
    return unless token

    uri = URI("#{DISCORD_API_BASE}/channels/#{channel_id}/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    # 2000文字制限対応（マルチバイト安全）
    chunks = split_message(message, 2000)
    chunks.each do |chunk|
      req = Net::HTTP::Post.new(uri.path)
      req["Authorization"] = "Bot #{token}"
      req["Content-Type"] = "application/json"
      req["User-Agent"] = "DiscordBot (memoria, 1.0)"
      req.body = { content: chunk }.to_json

      resp = http.request(req)
      unless resp.code.start_with?("2")
        Rails.logger.error("[MessageDispatcher] Discord API error: #{resp.code} #{resp.body[0..200]}")
      end
    end
  rescue => e
    Rails.logger.error("[MessageDispatcher] Discord send failed: #{e.message}")
  end

  def self.split_message(text, max_bytes)
    chunks = []
    current = +""
    text.each_char do |char|
      if (current + char).bytesize > max_bytes
        chunks << current
        current = +char
      else
        current << char
      end
    end
    chunks << current unless current.empty?
    chunks
  end
end
