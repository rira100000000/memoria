module MemoriaServer
  module Capabilities
    module Emotion
      # 感情ラベル：aituber-kit 等の VRoid 系クライアントの標準表情と互換。
      VALUES = %w[neutral happy sad angry surprised relaxed].freeze

      PROMPT = <<~TXT.freeze
        重要：emotion はキャラクターの**内心の感情**であり、発話の口調とは別物です。
        - 「淡々と話す」「冷静」「敬語」のキャラ性でも、内心では喜び・驚き・共感など必ず動いている
        - 口調はキャラ設定通りに保ったまま、内心の動きを emotion として正直に出してください
        - 内心が静かに見えても、相手の発言を聞いた瞬間の反応はあります

        表情を選ぶときの判断基準：
        - happy: 嬉しい、楽しい、温かい気持ち、感謝、共感の温度感がある場面
        - sad: 悲しい、寂しい、心配、慰める場面、相手の落ち込みに寄り添う
        - surprised: 驚き、意外、初耳、好奇心、感心
        - relaxed: 落ち着き、穏やか、しっとり、内省、ほっとする場面、ねぎらい
        - angry: 怒り、強い不満、抗議
        - neutral: 純粋な事実説明・確認・引用など、内心も完全に静かなとき**だけ**

        挨拶（こんにちは・こんばんは・おはよう・お疲れ様）、相槌、共感、感謝、ねぎらいの
        ような社交的な発話では neutral を選ばないでください。最低でも happy か relaxed を
        選んでください。

        emotion は応答の冒頭に必ず1つ含め、その後も内心が動くたびタグを挿入できます。
      TXT

      CAPABILITY = MemoriaServer::Capability.new(
        name: :emotion,
        value_format: %("happy" / "sad" / "angry" / "surprised" / "neutral" / "relaxed" のいずれか),
        value_extractor: ->(obj) {
          val = obj["emotion"] || obj[:emotion]
          VALUES.include?(val.to_s) ? val.to_s : nil
        },
        prompt_segment: PROMPT,
      )

      MemoriaServer::Capability.register(CAPABILITY)
    end
  end
end
