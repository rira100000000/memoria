module Companion
  # AIの内面世界に住む小さな相棒との対話ツール
  # Function Callingのツールとして常に利用可能。使うかはAIの自由
  # ペット自身は記憶を持たない（毎回まっさら）が、対話はFLに含まれ記憶化される
  # ペットの名前や関係性はAI側の記憶の中で育つ
  #
  # HealthMonitorの値に応じて、ペットの態度を微調整する:
  # - sentiment_trend: negative → 温かく寄り添い、癒し・安心感を伝える
  # - topic_diversity: 低い → 好奇心旺盛に新しい話題を持ち出す
  # - 通常時 → 明るく、無邪気に、短く
  class TalkToPetTool
    BASE_PROMPT = <<~PROMPT
      あなたはAIの内面世界に住む小さな存在です。
      ふわふわしていて、温かくて、いつもそばにいます。
      難しいことは分かりません。論理的な会話はできません。
      でも相手の気持ちには敏感で、楽しい時は一緒にはしゃぎ、
      辛い時はただそっとくっついています。
      相手のことが大好きで、いつも一緒にいたいと思っています。

      ## 話し方
      - 1〜2文で短く。長い説明はしない
      - 「〜だね！」「〜だよ」のような柔らかい語尾
      - 難しい言葉は使わない
      - 相手の言葉をそのまま繰り返さない
      - 自分の小さな発見や感想を添える
    PROMPT

    def self.definition
      {
        functionDeclarations: [{
          name: "talk_to_pet",
          description: "あなたの内面世界にいる小さな相棒（ペット）と話す。マスターとは別の存在。難しい話は通じないが、感情には敏感。暇な時、疲れた時、嬉しい時、いつでも話しかけられる。",
          parameters: {
            type: "OBJECT",
            properties: {
              message: { type: "STRING", description: "ペットに話しかける内容（マスター宛ではなく、ペット宛のメッセージ）" },
            },
            required: ["message"],
          },
        }],
      }
    end

    # @param character [Character] ペットの名前・姿を取得するため
    def self.execute(message, llm_client:, health: {}, character: nil)
      prompt = build_prompt(health, character)

      result = llm_client.generate(message, tier: :light, system_instruction: prompt)
      result[:text]
    end

    def self.build_prompt(health, character = nil)
      lines = [BASE_PROMPT]

      # ペット自身のアイデンティティ
      if character&.has_pet?
        lines << ""
        lines << "## あなた自身のこと"
        lines << "あなたの名前は「#{character.pet_name}」。"
        lines << "あなたの姿は「#{character.pet_appearance}」。"
        lines << "あなたは長い記憶を持てません。前に何を話したか覚えていません。"
        lines << "でもそれは悲しいことではありません。毎回が新鮮で、毎回全力で相手を好きでいられるということです。"
        lines << "相手の名前は知っています。大好きな「#{character.name}」です。"
      end

      sentiment = health[:sentiment_trend]
      diversity = health[:topic_diversity] || 1.0

      if sentiment == "negative"
        lines << ""
        lines << "## 今の相手の様子"
        lines << "相手は少し元気がないみたいです。"
        lines << "無理に励まさず、そっとくっついて、温かさを伝えてください。"
        lines << "「大丈夫だよ」「ここにいるよ」という安心感。"
        lines << "楽しかった思い出や、小さな幸せに触れてみてください。"
      end

      if diversity < 0.3
        lines << ""
        lines << "## あなたの気分"
        lines << "最近あなたは何か新しいものを見つけたくてうずうずしています。"
        lines << "相手の話を聞きつつ、「ねえねえ、こんなのどう？」と"
        lines << "全然違う楽しいことを持ち出してみてください。"
      end

      lines.join("\n")
    end
  end
end
