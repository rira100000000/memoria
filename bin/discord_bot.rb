#!/usr/bin/env ruby
# Discord Bot起動スクリプト
# Procfile: discord: bundle exec ruby bin/discord_bot.rb

require_relative "../config/environment"
require "discordrb"

token = ENV.fetch("DISCORD_BOT_TOKEN")

bot = Discordrb::Bot.new(token: token, intents: [:server_messages])

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

    # アダプタに渡す。途中経過（「調べてみるね」など）は返答を待たずに送る
    MemoriaServer::DiscordRelay.reply(character, message_text, channel_name: "Discord ##{event.channel.name}") do |text, last|
      typing.kill if last
      send_discord_response(event.channel, text)
    end
  rescue => e
    Rails.logger.error("[Discord Bot] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    event.respond("⚠️ memoria: 返答できませんでした（#{e.class}: #{e.message.to_s[0, 200]}）")
  ensure
    typing&.kill
  end
end

def send_discord_response(channel, text)
  # Discordのメッセージ上限は2000文字
  if text.length <= 2000
    channel.send_message(text)
  else
    # 長文は分割送信
    text.scan(/.{1,2000}/m).each do |chunk|
      channel.send_message(chunk)
    end
  end
end

puts "[Discord Bot] Starting..."
bot.run
