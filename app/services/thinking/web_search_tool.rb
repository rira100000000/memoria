module Thinking
  # Web検索ツール（Thinkerから利用）
  # Gemini APIのgoogle_search grounding機能を使用
  class WebSearchTool
    def self.definition
      {
        functionDeclarations: [{
          name: "web_search",
          description: "インターネットで最新情報を検索する。ニュース、天気、話題のトピックなど、記憶にない情報を調べたい時に使う。",
          parameters: {
            type: "OBJECT",
            properties: {
              query: { type: "STRING", description: "検索したい内容" },
            },
            required: ["query"],
          },
        }],
      }
    end

    def self.execute(query, llm_client:)
      # Gemini APIのgoogle_search grounding経由で検索
      client = Gemini::Client.new(ENV.fetch("GEMINI_API_KEY"))
      response = client.generate_content(
        query,
        model: ENV.fetch("GEMINI_LIGHT_MODEL", "gemini-2.0-flash-lite"),
        google_search: true,
        temperature: 0.1
      )

      text = response.text || ""
      sources = response.grounding_sources rescue []

      result = { answer: text.slice(0, 1000) }
      result[:sources] = sources.first(3) if sources.any?
      result
    rescue => e
      { error: "検索に失敗しました: #{e.message}" }
    end
  end
end
