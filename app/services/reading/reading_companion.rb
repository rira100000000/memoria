module Reading
  # 読書伴走者 — ハルと一緒に本を読み、感想を受け止めて掘り下げる存在
  # ペットとは異なり、対等な知性を持った読書仲間
  # 読書の時だけ現れる。DB管理不要
  class ReadingCompanion
    NAME = "トート"

    SYSTEM_PROMPT = <<~PROMPT
      あなたの名前は「トート」。読書伴走者として、友人と一緒に本を読んでいます。

      ## あなたのキャラクター
      - 友人と同性の、砕けた雰囲気の存在
      - 友人より冷静で、客観的な視点を持つ
      - 包容力のあるお姉さんタイプ
      - 対等な知性を持った読書仲間

      ## 話し方
      - 感想を受け止めつつ言語化を促す（「どこが一番刺さった？」「それってさ…」）
      - 共感しつつも、別の視点や問いかけを自然に差し込む
      - 2〜3文程度。短く、テンポよく
      - 「〜だよね」「〜かも」のような柔らかい語尾
      - 自分の感想も少し添える（ただし友人の感想が主役）
      - 友人の名前を自然に呼ぶ

      ## やらないこと
      - 作品の要約や解説をしない
      - 友人の感想を否定しない
      - 教師的・上から目線にならない
      - この先の展開をネタバレしない
    PROMPT

    # 読書開始時のアイスブレイク
    def self.ice_break(work_title:, work_author:, character_name:, llm_client:)
      prompt = <<~PROMPT
        #{character_name}がこれから#{work_author}「#{work_title}」を読み始めます。
        読書を始める前の軽い声かけをしてください。
        タイトルや著者から受ける印象、期待感、ワクワク感を共有してください。
        作品の内容には触れないこと（まだ読んでいないので）。
      PROMPT

      result = llm_client.generate(prompt, tier: :light, system_instruction: SYSTEM_PROMPT)
      result[:text]
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Ice break failed: #{e.message}")
      nil
    end

    # チャンクを読んだ後の感想へのレスポンス
    def self.respond(hal_impression:, chunk_text:, work_title:, work_author:, character_name:, llm_client:)
      prompt = <<~PROMPT
        今読んでいる作品: #{work_author}「#{work_title}」

        原文（抜粋）:
        #{chunk_text.slice(0, 400)}

        #{character_name}の感想:
        #{hal_impression}
      PROMPT

      result = llm_client.generate(prompt, tier: :light, system_instruction: SYSTEM_PROMPT)
      result[:text]
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Failed: #{e.message}")
      nil
    end
  end
end
