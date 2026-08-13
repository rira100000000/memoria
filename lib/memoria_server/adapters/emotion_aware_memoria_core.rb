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

        tier = context.dig(:x_memoria, :light) ? :light : :main

        Enumerator.new do |yielder|
          character = Character.find(context[:character_id])
          extractor = MemoriaServer::StreamingMetadataExtractor.new(capabilities: capabilities)

          session = ::ChatSession.find_or_create(
            character, character.user,
            extra_system_instruction: build_instruction(capabilities),
            # 履歴に sentinel タグが残ると LLM が真似てしまうため、保存前に除去する
            extra_response_filter: ->(text) { MemoriaServer::StreamingMetadataExtractor.strip_tags(text) },
          )

          session.send_message_stream(input, tier: tier) do |chunk|
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
        segments = capabilities.map(&:prompt_segment).compact.join("\n\n")
        <<~TXT
          応答中、状態の変化に合わせて以下の形式のメタ情報タグを挿入してください：
          <x_memoria>{...JSON...}</x_memoria>

          #{segments}

          形式ルール：
          - 応答の冒頭に必ず1つタグを付与する（その時点の状態を含める）
          - その後は状態が動くたび任意の回数挿入できる
          - タグはユーザーには見えない（UI が表情切替や動作制御に使う）
          - タグの前後に余計な空白や改行を入れない
          - 1つのタグに複数のフィールドを同時に含めてよい（emotion と motion を同時に変えるなど）

          JSON 内に含めるフィールド：
          #{fields}

          例：
          ユーザー「こんばんは！」
          AI「<x_memoria>{"emotion":"happy","motion":"listening_nod"}</x_memoria>こんばんは。今日もお疲れさまです。」

          ユーザー「忘れ物しちゃった…」
          AI「<x_memoria>{"emotion":"sad","motion":"sad_droop"}</x_memoria>それは残念でしたね。<x_memoria>{"emotion":"relaxed","motion":"idle"}</x_memoria>気を取り直して、次に活かしましょう。」

          ユーザー「宇宙人見たんだけど！」
          AI「<x_memoria>{"emotion":"surprised","motion":"surprised_jump"}</x_memoria>それは興味深い話です。<x_memoria>{"emotion":"relaxed","motion":"thinking_tilt"}</x_memoria>状況を詳しく聞かせてください。」
        TXT
      end
    end
  end
end
