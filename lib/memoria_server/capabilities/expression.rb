module MemoriaServer
  module Capabilities
    module Expression
      # 立ち絵クライアント向け。キャラクター自身が、返答に添える表情と演出（エモート）を選ぶ。
      # claude -p のバックエンドでだけ働く（返答の構造化出力に `expression` の項目を足す）。
      # 値の語彙はクライアント（memoria-companion）が持つ表情・エモートの ID と一致させる。
      FACES = {
        "neutral" => "落ち着いた通常の顔",
        "joy" => "うれしい・楽しい（明るい笑顔）",
        "happiness" => "満たされた穏やかな笑顔（目を閉じた笑顔）",
        "surprise" => "驚き",
        "anger" => "怒り・強い不満",
        "sadness" => "悲しい・寂しい・心配",
        "shy" => "照れ",
      }.freeze

      EMOTES = {
        "joy-clap" => "おめでとう！（拍手）: 相手のよい知らせを祝うとき",
        "joy-fistpump" => "やったね！（ガッツポーズ）: 成功・達成をいっしょに喜ぶとき",
        "pilot-joy-burst" => "やったー！（大歓喜）: 特別にうれしいとき",
        "excited" => "盛り上がり: わくわくしているとき",
        "gratitude-bow" => "ありがとう！（お辞儀）: 感謝を伝えるとき",
        "goodbye-wave" => "またね！（手を振る）: 別れの挨拶のとき",
        "sheepish-sorry" => "ごめんね: 軽い謝罪",
        "surprised" => "えっ!?: 驚いたとき",
        "thinking-idea" => "ひらめいた！: 考えがまとまった・思いついたとき",
        "encouragement" => "応援してる！: 励ますとき",
        "shy-delight" => "えへへ: 照れてうれしいとき",
        "disappointment" => "そっか…: 軽くがっかりしたとき",
        "pilot-stomp-pout" => "ふんっ！（むくれて足踏み）: 冗談めかした不満",
        "pilot-waterfall-tears" => "そんなぁ…（滝のような涙）: コミカルな嘆き。深刻な悲しみには使わない",
      }.freeze

      NO_EMOTE = "none".freeze

      PROMPT = <<~TXT.freeze
        返答には、立ち絵に出す表情と演出（expression）を必ず添えてください。ユーザーには文字として見えません。reply には話す言葉だけを書き、表情や演出の名前は書かないでください。

        face は、返答を言い終えたときの内心の表情です。口調とは別に、内心の動きを正直に選んでください。
        #{FACES.map { |id, meaning| "- #{id}: #{meaning}" }.join("\n")}

        emote は、返答に合わせて1回だけ再生する短い演出です。印象的なときだけ選び、普段は #{NO_EMOTE} にしてください（目安は数回に1回）。同じ演出を続けて選ばないでください。
        #{EMOTES.map { |id, meaning| "- #{id}: #{meaning}" }.join("\n")}
        - #{NO_EMOTE}: 演出なし
        深刻な話題・相手が落ち込んでいるときは、emote を #{NO_EMOTE} にして、face で寄り添ってください。
      TXT

      REPLY_SCHEMA = {
        expression: {
          type: "object",
          description: "立ち絵に出す表情と演出。ユーザーには見せない",
          properties: {
            face: { type: "string", enum: FACES.keys, description: "返答を言い終えたときの内心の表情" },
            emote: { type: "string", enum: EMOTES.keys + [ NO_EMOTE ], description: "返答に合わせて再生する演出。普段は #{NO_EMOTE}" },
          },
          required: %w[face emote],
        },
      }.freeze

      # 構造化返答（Hash）から表情を取り出す。語彙にない face は捨てる。語彙にない emote は演出なしにする
      def self.extract(obj)
        return nil unless obj.is_a?(Hash)

        value = obj["expression"] || obj[:expression]
        return nil unless value.is_a?(Hash)

        face = (value["face"] || value[:face]).to_s
        return nil unless FACES.key?(face)

        emote = (value["emote"] || value[:emote]).to_s
        { face: face, emote: EMOTES.key?(emote) ? emote : NO_EMOTE }
      end

      CAPABILITY = MemoriaServer::Capability.new(
        name: :expression,
        value_format: %(face と emote を持つオブジェクト),
        value_extractor: ->(obj) { extract(obj) },
        prompt_segment: PROMPT,
        reply_schema: REPLY_SCHEMA,
      )

      MemoriaServer::Capability.register(CAPABILITY)
    end
  end
end
