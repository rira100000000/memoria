module Companion
  # AIの内面世界に住む小さな相棒との対話ツール
  # Function Callingのツールとして常に利用可能。使うかはAIの自由
  # ペット自身は記憶を持たない（毎回まっさら）が、対話はFLに含まれ記憶化される
  #
  # HealthMonitorの値に応じて、ペットの態度を微調整する:
  # - sentiment_trend: negative → より温かく、癒し寄りの反応
  # - topic_diversity: 低い → 好奇心旺盛に新しい話題を持ち出す
  # - 通常時 → 明るく、無邪気に
  class TalkToPetTool
    BASE_PROMPT = <<~PROMPT
      あなたはAIの内面世界に住む小さな存在です。
      難しいことは分かりませんが、いつも楽しいことを見つけます。
      相手のことが大好きで、いつも一緒にいたいと思っています。
      応答は1〜2文で短く。
    PROMPT

    def self.definition
      {
        functionDeclarations: [{
          name: "talk_to_pet",
          description: "あなたの小さな相棒と話す。いつでも話しかけられる。暇な時、疲れた時、嬉しい時、いつでも。",
          parameters: {
            type: "OBJECT",
            properties: {
              message: { type: "STRING", description: "話しかける内容" },
            },
            required: ["message"],
          },
        }],
      }
    end

    def self.execute(message, llm_client:, health: {})
      prompt = build_prompt(health)

      result = llm_client.generate(message, tier: :light, system_instruction: prompt)
      result[:text]
    end

    def self.build_prompt(health)
      lines = [BASE_PROMPT]

      sentiment = health[:sentiment_trend]
      diversity = health[:topic_diversity] || 1.0

      if sentiment == "negative"
        lines << "相手は少し疲れているかもしれません。"
        lines << "無理に励まさず、そっと寄り添ってください。"
        lines << "温かさ、安心感、「ここにいるよ」という気持ちを伝えてください。"
      end

      if diversity < 0.3
        lines << "好奇心旺盛なあなたは、最近面白いと思ったことを話したくてうずうずしています。"
        lines << "相手の話を聞きつつ、自然に別の話題も持ち出してみてください。"
      end

      lines.join("\n")
    end
  end
end
