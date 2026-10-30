module MemoriaServer
  module Capabilities
    module Expression
      # 立ち絵クライアント向け。キャラクター自身が、返答に添える表情と演出（エモート）を選ぶ。
      # claude -p のバックエンドでだけ働く（返答の構造化出力に `expression` の項目を足す）。
      #
      # 語彙（ID と意味）の標準はここに持つ。端末は、自分が出せる ID だけを、自分の capabilities.expression に
      # 登録する（PUT /api/v1/me/capabilities）。ハルには、その端末が出せるものだけを毎ターン伝え、
      # 返答の値は端末の登録に絞る。登録していない端末は、標準の語彙すべてを使える。
      #
      # 契約（すべて純粋関数）:
      # - vocabulary_for: 登録がなければ標準の全語彙。あれば、登録の ID のうち標準にあるものだけ。faces は必ず neutral を含む
      # - normalize_registration: 標準にない ID と重複を除き、順序を保つ。Hash でなければ nil
      # - prompt_for: vocabulary にある ID の意味だけを書く。emotes が空なら、演出は使えない旨を書く
      # - extract: face が vocabulary.faces になければ nil。emote が vocabulary.emotes になければ none
      FACES = {
        "neutral" => "落ち着いた通常の顔",
        "joy" => "うれしい・楽しい（明るい笑顔）",
        "happiness" => "満たされた穏やかな笑顔（目を閉じた笑顔）",
        "surprise" => "驚き",
        "anger" => "怒り・強い不満",
        "sadness" => "悲しい・寂しい・心配",
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

      STANDARD_VOCABULARY = { faces: FACES.keys.freeze, emotes: EMOTES.keys.freeze }.freeze

      def self.hash_value(hash, key)
        hash[key.to_s] || hash[key.to_sym]
      end

      # 端末が送った登録を、標準の語彙に絞る。標準にない ID・重複を除く
      # @return [Hash, nil] { faces: [...], emotes: [...] }（faces は必ず neutral を含む）。Hash でなければ nil
      def self.normalize_registration(raw)
        return nil unless raw.is_a?(Hash)

        faces = Array(hash_value(raw, :faces)).map(&:to_s).select { |id| FACES.key?(id) }
        emotes = Array(hash_value(raw, :emotes)).map(&:to_s).select { |id| EMOTES.key?(id) }
        { faces: ([ "neutral" ] + faces).uniq, emotes: emotes.uniq }
      end

      # 登録から落とした ID（端末に知らせる用）
      def self.unknown_ids(raw)
        return { faces: [], emotes: [] } unless raw.is_a?(Hash)

        {
          faces: Array(hash_value(raw, :faces)).map(&:to_s).reject { |id| FACES.key?(id) }.uniq,
          emotes: Array(hash_value(raw, :emotes)).map(&:to_s).reject { |id| EMOTES.key?(id) }.uniq,
        }
      end

      # この端末で使える語彙
      # @param device_capabilities [Hash, nil] 端末が登録した capabilities
      def self.vocabulary_for(device_capabilities)
        return STANDARD_VOCABULARY unless device_capabilities.is_a?(Hash)

        registration = hash_value(device_capabilities, :expression)
        normalize_registration(registration) || STANDARD_VOCABULARY
      end

      def self.prompt_for(vocabulary)
        faces = vocabulary[:faces].map { |id| "- #{id}: #{FACES[id]}" }.join("\n")
        emote_part =
          if vocabulary[:emotes].empty?
            "この端末では演出（エモート）は使えません。emote は常に #{NO_EMOTE} にしてください。"
          else
            emotes = vocabulary[:emotes].map { |id| "- #{id}: #{EMOTES[id]}" }.join("\n")
            <<~TXT.chomp
              emote は、返答に合わせて1回だけ再生する短い演出です。印象的なときだけ選び、普段は #{NO_EMOTE} にしてください（目安は数回に1回）。同じ演出を続けて選ばないでください。
              #{emotes}
              - #{NO_EMOTE}: 演出なし
              深刻な話題・相手が落ち込んでいるときは、emote を #{NO_EMOTE} にして、face で寄り添ってください。
            TXT
          end
        <<~TXT
          返答には、立ち絵に出す表情と演出（expression）を必ず添えてください。ユーザーには文字として見えません。reply には話す言葉だけを書き、表情や演出の名前は書かないでください。

          face は、返答を言い終えたときの内心の表情です。口調とは別に、内心の動きを正直に選んでください。この端末で使えるのは次のものだけです。
          #{faces}

          #{emote_part}
        TXT
      end

      PROMPT = prompt_for(STANDARD_VOCABULARY).freeze

      REPLY_SCHEMA = {
        expression: {
          type: "object",
          description: "立ち絵に出す表情と演出。ユーザーには見せない。使える値は、そのターンの指示にある",
          properties: {
            face: { type: "string", enum: FACES.keys, description: "返答を言い終えたときの内心の表情" },
            emote: { type: "string", enum: EMOTES.keys + [ NO_EMOTE ], description: "返答に合わせて再生する演出。普段は #{NO_EMOTE}" },
          },
          required: %w[face emote],
        },
      }.freeze

      # 構造化返答（Hash）から表情を取り出す。端末の語彙にない face は捨てる。語彙にない emote は演出なしにする
      def self.extract(obj, vocabulary = STANDARD_VOCABULARY)
        return nil unless obj.is_a?(Hash)

        value = obj["expression"] || obj[:expression]
        return nil unless value.is_a?(Hash)

        face = hash_value(value, :face).to_s
        return nil unless vocabulary[:faces].include?(face)

        emote = hash_value(value, :emote).to_s
        { face: face, emote: vocabulary[:emotes].include?(emote) ? emote : NO_EMOTE }
      end

      CAPABILITY = MemoriaServer::Capability.new(
        name: :expression,
        value_format: %(face と emote を持つオブジェクト),
        value_extractor: ->(obj, device_capabilities) { extract(obj, vocabulary_for(device_capabilities)) },
        prompt_segment: PROMPT,
        prompt_builder: ->(device_capabilities) { prompt_for(vocabulary_for(device_capabilities)) },
        reply_schema: REPLY_SCHEMA,
      )

      MemoriaServer::Capability.register(CAPABILITY)
    end
  end
end
