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
          Thinking::ScheduleTools.definitions(autonomous: true)[:functionDeclarations]
        when :chat
          # 予定の結果は連絡手段（Discord）に届くので、会話からの追加もDiscord経由に限る
          return [] unless platform == :discord

          Thinking::ScheduleTools.definitions(autonomous: false)[:functionDeclarations]
        else
          []
        end
      end

      def execute(tool_name, args, character:, scene:)
        Thinking::ScheduleTools.execute(tool_name, args, character: character, autonomous: scene == :thinking)
      end
    end
  end
end

MemoriaServer::Plugin.register(MemoriaServer::Plugins::Schedule.new)
