require_relative "schedule_tools"

module MemoriaServer
  module Plugins
    # 予定の確認・追加・取り消し（繰り返しの予定と承認を含む）
    class Schedule < MemoriaServer::Plugin
      def name
        :schedule
      end

      def tools(scene:, platform: nil)
        case scene
        when :thinking
          ScheduleTools.definitions(autonomous: true)[:functionDeclarations]
        when :chat
          # 予定の結果は連絡手段（Discord）に届くので、会話からの追加もDiscord経由に限る
          return [] unless platform == :discord

          ScheduleTools.definitions(autonomous: false)[:functionDeclarations]
        else
          []
        end
      end

      # 予定の送り先に使える種類。チャンネルに種類を割り当てていないときは出さない
      def prompt_segment(character, scene:)
        purposes = character.channel_bindings.flat_map(&:purposes).uniq - [ChannelBinding::DEFAULT, ChannelBinding::SYSTEM]
        return nil if purposes.empty?

        "## 予定の送り先\n" \
          "add_schedule の to に指定できる種類: #{purposes.join(", ")}。省略すると既定のチャンネルに届く。" \
          "ユーザーと話している途中で起きたときは、話の続きとして、その種類のチャンネルに届く"
      end

      def execute(tool_name, args, character:, scene:)
        ScheduleTools.execute(tool_name, args, character: character, autonomous: scene == :thinking)
      end
    end
  end
end

MemoriaServer::Plugin.register(MemoriaServer::Plugins::Schedule.new)
