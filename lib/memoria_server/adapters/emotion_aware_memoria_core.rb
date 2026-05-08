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
          応答中、感情やニュアンスの変化に合わせて以下の形式のメタ情報タグを挿入してください：
          <x_memoria>{...JSON...}</x_memoria>

          ルール：
          - 応答の冒頭に必ず1つ付与してください（最初の感情/状態の宣言）
          - その後は変化があれば任意の回数挿入できます
          - タグはユーザーには見えませんが、UI が表情や動作の切替えに使います
          - タグの前後に余計な空白や改行を入れないでください

          JSON 内に含めるフィールド：
          #{fields}
        TXT
      end
    end
  end
end
