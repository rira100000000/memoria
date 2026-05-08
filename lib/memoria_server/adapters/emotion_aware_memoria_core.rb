module MemoriaServer
  module Adapters
    # MemoriaCore アダプタを継承し、capability ベースのメタ情報出力をサポートする。
    #
    # クライアントが `x_memoria.wants` でほしい capability（例 ["emotion"]）を宣言すると、
    # このアダプタは LLM の system prompt に出力形式の追加指示を注入し、
    # ストリーム中の `<x_memoria>{...}</x_memoria>` タグを抽出して
    # `{x_memoria: {...}}` チャンクとして yield する。
    #
    # `wants` が空の場合は親クラス（MemoriaCore）の挙動と同じ。
    class EmotionAwareMemoriaCore < MemoriaCore
      def respond(input, context:)
        wants = Array(context.dig(:x_memoria, :wants))
        capabilities = MemoriaServer::Capability.resolve_many(wants)

        return super if capabilities.empty?

        Enumerator.new do |yielder|
          character = Character.find(context[:character_id])
          extractor = MemoriaServer::StreamingMetadataExtractor.new(capabilities: capabilities)

          session = ::ChatSession.find_or_create(
            character, character.user,
            extra_system_instruction: build_instruction(capabilities),
            # 履歴に sentinel タグが残ると LLM が真似てしまうため、保存前に除去する
            extra_response_filter: ->(text) { MemoriaServer::StreamingMetadataExtractor.strip_tags(text) },
          )

          session.send_message_stream(input) do |chunk|
            if chunk[:delta]
              extractor.feed(chunk[:delta]) do |kind, payload|
                if kind == :text
                  yielder << { delta: payload } unless payload.empty?
                elsif kind == :metadata
                  yielder << { x_memoria: payload } unless payload.empty?
                end
              end
            elsif chunk[:done]
              # 残りバッファを flush（タグ閉じ忘れ等のとき）
              extractor.finalize do |kind, payload|
                if kind == :text
                  yielder << { delta: payload } unless payload.empty?
                elsif kind == :metadata
                  yielder << { x_memoria: payload } unless payload.empty?
                end
              end
              yielder << { done: true, metadata: { usage: chunk[:usage] } }
            end
          end
        end
      end

      private

      def build_instruction(capabilities)
        fields = capabilities.map { |c| "  - #{c.name}: #{c.value_format}" }.join("\n")
        <<~TXT
          応答中、表情の変化に合わせて以下の形式のメタ情報タグを必ず挿入してください：
          <x_memoria>{...JSON...}</x_memoria>

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

          形式ルール：
          - 応答の冒頭に必ず1つタグを付与する
          - その後は感情が動くたび任意の回数挿入できる（1〜2文ごとに見直す）
          - タグはユーザーには見えない（UI が表情切替に使う）
          - タグの前後に余計な空白や改行を入れない

          JSON 内に含めるフィールド：
          #{fields}

          例（淡々と話すキャラの場合）：
          ユーザー「こんばんは！」
          AI「<x_memoria>{"emotion":"happy"}</x_memoria>こんばんは。今日もお疲れさまです。」

          ユーザー「忘れ物しちゃった…」
          AI「<x_memoria>{"emotion":"sad"}</x_memoria>それは残念でしたね。<x_memoria>{"emotion":"relaxed"}</x_memoria>気を取り直して、次に活かしましょう。」

          ユーザー「宇宙人見たんだけど！」
          AI「<x_memoria>{"emotion":"surprised"}</x_memoria>それは興味深い話です。<x_memoria>{"emotion":"relaxed"}</x_memoria>状況を詳しく聞かせてください。」
        TXT
      end
    end
  end
end
