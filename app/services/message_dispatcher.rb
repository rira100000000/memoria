# キャラクターからのメッセージを外部チャネルに送信する
# 現在はDiscordのみ対応。将来LINE等を追加
class MessageDispatcher
  def self.dispatch(character, message)
    return if message.blank?

    character.channel_bindings.discord.each do |binding|
      send_to_discord(binding.channel_id, message)
    end
  end

  def self.send_to_discord(channel_id, message)
    token = ENV["DISCORD_BOT_TOKEN"]
    return unless token

    require "discordrb/webhooks" rescue nil

    # REST APIでメッセージ送信（Bot起動プロセス外からでも送れる）
    conn = Faraday.new(url: "https://discord.com/api/v10") do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end

    # 2000文字制限対応
    message.scan(/.{1,2000}/m).each do |chunk|
      conn.post("/channels/#{channel_id}/messages", { content: chunk }) do |req|
        req.headers["Authorization"] = "Bot #{token}"
      end
    end
  rescue => e
    Rails.logger.error("[MessageDispatcher] Discord send failed: #{e.message}")
  end
end
