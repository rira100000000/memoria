#!/usr/bin/env ruby
# Discord Bot起動スクリプト
# Procfile: discord: bundle exec ruby bin/discord_bot.rb

require_relative "../config/environment"
require "discordrb"

token = ENV.fetch("DISCORD_BOT_TOKEN")

bot = Discordrb::Bot.new(token: token, intents: [:server_messages])

bot.ready do |event|
  puts "[Discord Bot] Online! (#{event.bot.profile.username})"
end

bot.message do |event|
  # Bot自身のメッセージは無視
  next if event.author.bot_account?

  channel_id = event.channel.id.to_s
  character = ChannelBinding.find_character_for_discord(channel_id)

  unless character
    # バインドされていないチャンネルは無視
    next
  end

  user = character.user
  message_text = event.content

  # 空メッセージは無視
  next if message_text.strip.empty?

  begin
    # タイピング表示
    event.channel.start_typing

    # ChatSessionを取得または作成（予定・ペットなどのツールはプラグインが platform: :discord で出す）
    channel_name = "Discord ##{event.channel.name}"
    session = ChatSession.find_or_create(character, user,
      channel: channel_name,
      platform: :discord
    )
    result = session.send_message(message_text)

    # 応答を送信（2000文字制限対応）
    response_text = result[:response]
    send_discord_response(event.channel, response_text)

    # タイムアウトワーカーをスケジュール
    schedule_timeout(session.record)

  rescue => e
    Rails.logger.error("[Discord Bot] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    event.respond("ごめんね、ちょっとエラーが起きちゃった…🥺")
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

def schedule_timeout(record)
  # 既存のタイムアウトジョブのキャンセルは不要：
  # ジョブ側で message_count を比較して新しいメッセージがあれば早期 return する
  ConversationTimeoutJob
    .set(wait: ConversationTimeoutJob::TIMEOUT_MINUTES.minutes)
    .perform_later(record.id, record.message_count)
end

puts "[Discord Bot] Starting..."
bot.run
