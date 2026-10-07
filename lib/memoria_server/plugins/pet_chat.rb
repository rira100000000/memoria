module MemoriaServer
  module Plugins
    # Discordでの会話中にペットへ話しかける
    # 思考ループ側のペット（talk_to_pet / adopt_pet）は、FLへの記録と結びついているため Thinker に残している
    class PetChat < MemoriaServer::Plugin
      def name
        :pet_chat
      end

      def enabled_for?(character)
        character.has_pet?
      end

      def tools(scene:, platform: nil)
        return [] unless scene == :chat && platform == :discord

        Companion::TalkToPetTool.definition[:functionDeclarations]
      end

      def execute(tool_name, args, character:, scene:)
        return { error: "Unknown tool: #{tool_name}" } unless tool_name == "talk_to_pet"

        health = begin
          Thinking::ThoughtHealthMonitor.report(MemoriaCore::Core.new(character.vault_path))
        rescue StandardError
          {}
        end
        pet_response = Companion::TalkToPetTool.execute(
          args["message"],
          llm_client: LlmClient.new,
          health: health,
          character: character
        )
        pet_text = pet_response.is_a?(Hash) ? pet_response[:response].to_s : pet_response.to_s
        pet_name = character.pet_name || "ペット"
        {
          response: pet_text,
          log: [
            "#{character.name} → #{pet_name}: #{args["message"]}",
            "#{pet_name}: #{pet_text}"
          ],
        }
      end
    end
  end
end

MemoriaServer::Plugin.register(MemoriaServer::Plugins::PetChat.new)
