module Reading
  # 読書仲間のトートに話しかけるツール
  # TalkToPetToolと同じ構造。ハルが自発的に使う
  class TalkToCompanionTool
    def self.definition
      {
        functionDeclarations: [{
          name: "talk_to_reading_companion",
          description: "読書仲間の「#{ReadingCompanion::NAME}」に話しかける。読書中に感想を共有したり、気になった場面について語り合える。読書中でないと使えない。",
          parameters: {
            type: "OBJECT",
            properties: {
              message: {
                type: "STRING",
                description: "#{ReadingCompanion::NAME}に話しかける内容",
              },
            },
            required: ["message"],
          },
        }],
      }
    end

    def self.execute(message, llm_client:, character:)
      progress = character.current_reading
      return { error: "読書中ではありません" } unless progress

      companion = ReadingCompanion.new(llm_client: llm_client, for_character: character)
      response = companion.respond(
        message: message,
        work_title: progress.title,
        work_author: progress.author,
        character_name: character.name
      )

      { response: response || "" }
    end
  end
end
