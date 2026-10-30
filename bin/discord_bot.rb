#!/usr/bin/env ruby
# Discord Bot起動スクリプト
# Procfile: discord: bundle exec ruby bin/discord_bot.rb

require_relative "../config/environment"
require "discordrb"

token = ENV.fetch("DISCORD_BOT_TOKEN")

bot = Discordrb::Bot.new(token: token, intents: [:server_messages])

# MEMORIA_SERVER_URL があれば、返答はサーバー（memoria-server。常駐の claude を持つ）に頼む。
# なければ、これまでどおりこのプロセスの中で作る
server_url = ENV["MEMORIA_SERVER_URL"].to_s.strip
abort "MEMORIA_SERVER_URL が設定されていますが、bot の鍵（MEMORIA_BOT_TOKEN または MEMORIA_BOT_TOKEN_FILE）がありません" if !server_url.empty? && MemoriaServer::DiscordBotToken.current.to_s.empty?
server_client = server_url.empty? ? nil : MemoriaServer::DiscordClient.new(base_url: server_url, token: MemoriaServer::DiscordBotToken.current.to_s)

# 応答する相手のDiscordユーザーID（","区切り）。未設定ならチャンネルに書ける全員に応答する。
# キャラクターに強い権限（ファイルの編集やコマンドの実行）を渡すときは必ず設定する
allowed_user_ids = ENV["DISCORD_ALLOWED_USER_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)

bot.ready do |event|
  puts "[Discord Bot] Online! (#{event.bot.profile.username})"
end

bot.message do |event|
  # Bot自身のメッセージは無視
  next if event.author.bot_account?
  next if allowed_user_ids.any? && !allowed_user_ids.include?(event.author.id.to_s)

  channel_id = event.channel.id.to_s
  character = ChannelBinding.find_character_for_discord(channel_id)

  unless character
    # バインドされていないチャンネルは無視
    next
  end

  message_text = event.content

  # 空メッセージは無視
  next if message_text.strip.empty?

  typing = nil
  begin
    # タイピング表示。Discord の表示は10秒ほどで消えるので、返答するまで出し直す
    typing = Thread.new do
      loop do
        event.channel.start_typing
        sleep 8
      rescue => e
        Rails.logger.warn("[Discord Bot] typing failed: #{e.message}")
        sleep 8
      end
    end

    # 途中経過（「調べてみるね」など）は返答を待たずに送る
    deliver = lambda do |text, last|
      typing.kill if last
      send_discord_response(event.channel, text)
    end
    if server_client
      server_client.reply(channel_id: channel_id, channel_name: event.channel.name, author_id: event.author.id, text: message_text, &deliver)
    else
      MemoriaServer::DiscordRelay.reply(character, message_text, channel_name: "Discord ##{event.channel.name}", &deliver)
    end
  rescue => e
    Rails.logger.error("[Discord Bot] Error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    event.respond(MemoriaServer::DiscordClient.failure_text(e))
  ensure
    typing&.kill
  end
end

def send_discord_response(channel, text)
  # Discordのメッセージ上限（2000文字）に収まるよう、長文は分割して送る
  MemoriaServer::DiscordProtocol.split_message(text).each { |chunk| channel.send_message(chunk) }
end

puts "[Discord Bot] Starting..."
bot.run
