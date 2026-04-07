module Reading
  # 作品テキストを語りのリズムを意識した区切りに分割する前処理
  # 実況配信のテンポを意識: 淡々とした場面は長め、緊迫場面は短く、名言は一文
  class ChunkPreprocessor
    MAX_CHUNK = 500
    FALLBACK_TARGET = 300

    def self.call(text, llm_client:)
      return [{ "end" => text.length, "label" => "全文" }] if text.length <= MAX_CHUNK

      boundaries = generate_boundaries(text, llm_client)
      boundaries.presence || fallback_boundaries(text)
    end

    class << self
      private

      def generate_boundaries(text, llm_client)
        # 長すぎるテキストは先頭部分でプロンプトを構築し全文の文字位置を指定させる
        prompt = <<~PROMPT
          以下のテキストを、読書実況に適したチャンクに分割してください。

          ## 分割の原則
          - 淡々とした描写や説明 → やや長め（300〜500字）
          - 緊張が高まる場面、展開が動く場面 → 短め（100〜200字）
          - 名言、衝撃的な一文、クライマックス → 一文だけ切り出す
          - 最大500字、最小は一文
          - 語りのリズムを意識する。聞いている人が飽きず、かつ盛り上がりで息を飲むような緩急

          ## テキスト（全#{text.length}字）
          #{text}

          ## 出力形式
          各チャンクの終了位置（文字数）とラベルをJSON配列で返してください。
          endは0始まりの文字位置で、そのチャンクの末尾の次の位置です。
          最後のチャンクのendはテキスト全体の長さ（#{text.length}）にしてください。

          ```json
          [
            {"end": 245, "label": "導入"},
            {"end": 680, "label": "事件発覚"},
            ...
            {"end": #{text.length}, "label": "結末"}
          ]
          ```
          JSON配列のみを返してください。
        PROMPT

        result = llm_client.generate(prompt, tier: :light)
        parse_boundaries(result[:text], text.length)
      rescue => e
        Rails.logger.warn("[ChunkPreprocessor] LLM failed: #{e.message}")
        nil
      end

      def parse_boundaries(response_text, text_length)
        json_match = response_text.match(/```json\s*(.*?)\s*```/m)
        json_str = json_match ? json_match[1] : response_text
        boundaries = JSON.parse(json_str)

        return nil unless boundaries.is_a?(Array) && boundaries.size >= 1

        # バリデーション: endが昇順でtext_length以下
        boundaries = boundaries.select { |b| b["end"].is_a?(Integer) && b["end"] > 0 }
        boundaries.sort_by! { |b| b["end"] }
        boundaries.last["end"] = text_length if boundaries.any? # 最後は必ずテキスト末尾

        # 重複・逆転を除去
        cleaned = []
        prev_end = 0
        boundaries.each do |b|
          next if b["end"] <= prev_end
          cleaned << { "end" => b["end"], "label" => b["label"].to_s }
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

          # 句点で区切る
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
