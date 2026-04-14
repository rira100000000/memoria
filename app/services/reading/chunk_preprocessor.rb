module Reading
  # 作品テキストを語りのリズムを意識した区切りに分割する前処理
  # 句点・改行で文に分割し、インデックスを付けてLLMに区切り位置を選ばせる
  class ChunkPreprocessor
    MAX_CHUNK = 500
    FALLBACK_TARGET = 300

    def self.call(text, llm_client:)
      return [{ "end" => text.length, "label" => "全文" }] if text.length <= MAX_CHUNK

      sentences = split_into_sentences(text)
      return [{ "end" => text.length, "label" => "全文" }] if sentences.size <= 1

      boundaries = generate_boundaries(sentences, llm_client)
      boundaries.presence || fallback_boundaries(text)
    end

    class << self
      private

      # テキストを句点・改行で分割し、各文にインデックスと文字位置を付与
      def split_into_sentences(text)
        sentences = []
        pos = 0
        # 句点(。)で終わる文、または改行で終わる塊を1文として切り出す
        text.scan(/.+?。|.+?\n|.+\z/m) do |match|
          match_start = Regexp.last_match.begin(0)
          match_end = Regexp.last_match.end(0)
          stripped = match.strip
          next if stripped.empty?
          sentences << {
            index: sentences.size + 1,
            text: stripped,
            start: match_start,
            end: match_end,
          }
        end
        sentences
      end

      def generate_boundaries(sentences, llm_client)
        # インデックス付きの文一覧を構築
        indexed_text = sentences.map { |s| "[#{s[:index]}] #{s[:text]}" }.join("\n")

        prompt = <<~PROMPT
          以下は小説のテキストを文ごとに分割し、インデックスを付けたものです。

          #{indexed_text}

          ## タスク
          このテキストを読書実況に適したチャンクに分割してください。
          各チャンクの「最後の文のインデックス」と「チャンクのラベル」を指定してください。

          ## 分割の原則
          - 淡々とした描写や説明 → 複数の文をまとめる
          - 緊張が高まる場面、展開が動く場面 → 少ない文数で短く
          - 名言、衝撃的な一文、クライマックス → 一文だけで切り出す
          - 語りのリズムを意識する。実況で聞いている人が盛り上がるような緩急

          ## 出力形式
          ```json
          [
            {"last_index": 5, "label": "導入", "temperature": "静"},
            {"last_index": 8, "label": "事件発覚", "temperature": "動"},
            {"last_index": #{sentences.last[:index]}, "label": "結末", "temperature": "熱"}
          ]
          ```
          - temperatureは物語のその場面の空気感: "静"(説明・描写・導入。穏やか)、"動"(展開・会話・変化)、"熱"(事件・感情爆発・クライマックス)
          - 最後のチャンクのlast_indexは必ず#{sentences.last[:index]}にしてください。
          JSON配列のみを返してください。
        PROMPT

        result = llm_client.generate(prompt, tier: :light)
        parse_boundaries(result[:text], sentences)
      rescue => e
        Rails.logger.warn("[ChunkPreprocessor] LLM failed: #{e.message}")
        nil
      end

      def parse_boundaries(response_text, sentences)
        json_match = response_text.match(/```json\s*(.*?)\s*```/m)
        json_str = json_match ? json_match[1] : response_text
        raw = JSON.parse(json_str)

        return nil unless raw.is_a?(Array) && raw.size >= 1

        max_index = sentences.last[:index]
        boundaries = []

        raw.each do |entry|
          idx = entry["last_index"].to_i
          next if idx <= 0 || idx > max_index

          sentence = sentences.find { |s| s[:index] == idx }
          next unless sentence

          boundaries << {
            "end" => sentence[:end],
            "label" => entry["label"].to_s,
            "temperature" => entry["temperature"].to_s.presence || "動",
          }
        end

        return nil if boundaries.empty?

        # 最後は必ずテキスト末尾
        boundaries.last["end"] = sentences.last[:end]

        # 重複・逆転を除去
        cleaned = []
        prev_end = 0
        boundaries.sort_by { |b| b["end"] }.each do |b|
          next if b["end"] <= prev_end
          cleaned << b
          prev_end = b["end"]
        end

        cleaned.size >= 1 ? cleaned : nil
      rescue JSON::ParserError
        nil
      end

      def fallback_boundaries(text)
        boundaries = []
        pos = 0
        while pos < text.length
          target = pos + FALLBACK_TARGET
          break boundaries << { "end" => text.length, "label" => "" } if target >= text.length

          region = text[[target - 100, pos].max...[target + 100, text.length].min]
          if region && (idx = region.index("。"))
            chunk_end = [target - 100, pos].max + idx + 1
          else
            chunk_end = target
          end

          boundaries << { "end" => chunk_end, "label" => "" }
          pos = chunk_end
        end
        boundaries
      end
    end
  end
end
