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

    # ChatSessionを取得または作成（アプリ層ツールを注入）
    channel_name = "Discord ##{event.channel.name}"
    tools, executor = build_app_tools(character)
    session = ChatSession.find_or_create(character, user,
      channel: channel_name,
      extra_tools: tools,
      extra_tool_executor: executor
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

def build_app_tools(character)
  tools = []
  tools << Thinking::ScheduleTools.definitions

  health = {}
  if character.has_pet?
    tools << Companion::TalkToPetTool.definition
    health = Thinking::ThoughtHealthMonitor.report(
      MemoriaCore::Core.new(character.vault_path)
    ) rescue {}
  end

  pet_name = character.pet_name || "ペット"

  executor = ->(name, args) {
    case name
    when "talk_to_pet"
      next nil unless character.has_pet?
      pet_response = Companion::TalkToPetTool.execute(
        args["message"],
        llm_client: LlmClient.new,
        health: health,
        character: character
      )
      pet_text = pet_response.is_a?(Hash) ? pet_response[:response].to_s : pet_response.to_s
      {
        response: pet_text,
        log: [
          "#{character.name} → #{pet_name}: #{args["message"]}",
          "#{pet_name}: #{pet_text}",
        ],
      }
    when "list_schedules", "add_schedule", "cancel_schedule"
      Thinking::ScheduleTools.execute(name, args, character: character)
    end
    # nilを返すとChatSessionの内蔵ツールにフォールバック
  }

  [tools, executor]
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
