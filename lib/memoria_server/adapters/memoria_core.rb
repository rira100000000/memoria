module MemoriaServer
  module Adapters
    # Memoria 同梱のリファレンス実装アダプタ。
    # 既存の ChatSession / ContextRetriever / ReflectionService を respond contract に合わせてラップする。
    #
    # 永続化キー：character_id。ChatSessionRecord は character × user で active 1件だが、
    # 各 Character は user_id を持つため、character.user を使えば多ユーザ対応できる。
    # 既存の Memoria キャラ（ハル等）もそのまま MS 経由で動作する。
    class MemoriaCore < MemoriaServer::Adapter
      def boot
        # 既存ジョブ（SleepPhaseJob / TagProfilingJob / ThinkingLoopJob）は
        # ChatSession#reset! や Character#enable_thinking_loop! で per-character に
        # スケジュールされるため、boot 時に追加で行う登録はない。
      end

      def respond(input, context:)
        character_id = context[:character_id]
        Enumerator.new do |yielder|
          character = Character.find(character_id)
          session = build_session(character)
          session.send_message_stream(input) do |chunk|
            if chunk[:delta]
              yielder << { delta: chunk[:delta], emotion: nil }
            elsif chunk[:done]
              yielder << { done: true, metadata: { usage: chunk[:usage] } }
            end
          end
        end
      end

      def on_boundary(character_id:, reason:)
        character = Character.find(character_id)
        session = ::ChatSession.find_active(character, character.user)
        return nil unless session
        # reset! は会話履歴の振り返り（SN生成）→セッションクローズを行う。
        # 次回リクエストで新しい ChatSessionRecord が active になり、短期文脈がクリアされる。
        # 長期記憶（SN/TPN/EmbeddingStore）は残るため「翌朝の挨拶」のような境界に最適。
        session.reset!
      end

      def history(character_id:, limit: 50)
        character = Character.find(character_id)
        record = ::ChatSessionRecord.active.find_by(character: character, user: character.user)
        return [] unless record
        Array(record.messages).last(limit).map do |m|
          {
            role: m["role"] == "model" ? "assistant" : m["role"],
            content: m["content"],
            at: nil  # ChatSessionRecord は per-message の timestamp を持たない（FL ログには記録）
          }
        end
      end

      private

      def build_session(character)
        ::ChatSession.find_or_create(character, character.user)
      end
    end
  end
end
