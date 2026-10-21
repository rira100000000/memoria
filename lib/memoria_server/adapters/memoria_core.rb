module MemoriaServer
  module Adapters
    # Memoria 同梱のリファレンス実装アダプタ。
    # 既存の ChatSession / ContextRetriever / ReflectionService を respond contract に合わせてラップする。
    #
    # 永続化キー：character_id。ChatSessionRecord は character × user で active 1件だが、
    # 各 Character は user_id を持つため、character.user を使えば多ユーザ対応できる。
    # 既存の Memoria キャラもそのまま MS 経由で動作する。
    class MemoriaCore < MemoriaServer::Adapter
      def boot
        # 既存ジョブ（SleepPhaseJob / TagProfilingJob / ThinkingLoopJob）は
        # ChatSession#reset! や Character#enable_thinking_loop! で per-character に
        # スケジュールされるため、boot 時に追加で行う登録はない。
      end

      def respond(input, context:)
        character_id = context[:character_id]
        tier = context.dig(:x_memoria, :light) ? :light : :main
        Enumerator.new do |yielder|
          character = Character.find(character_id)
          session = build_session(character, context)
          if session.use_claude_cli?
            # claude -p は返答を最後にまとめて返す。ツールを使う前に書いた文（「調べてみるね」など）と、
            # 続けて動くときの途中の返答は、そのつど区切りの付いたメッセージとして先に返す
            result = session.send_message(input, on_progress: ->(text) {
              yielder << { delta: text }
              yielder << { message_break: true }
            })
            yielder << { delta: result[:response] }
            yielder << { done: true, metadata: { usage: result[:usage] } }
          else
            session.send_message_stream(input, tier: tier) do |chunk|
              if chunk[:delta]
                yielder << { delta: chunk[:delta] }
              elsif chunk[:done]
                yielder << { done: true, metadata: { usage: chunk[:usage] } }
              end
            end
          end
          schedule_timeout(session.record)
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

      def wake(character_id:, wakeup: nil)
        ::Thinking::Wake.run(Character.find(character_id), wakeup: wakeup)
      end

      # 送った連絡を会話の履歴に入れる。返事が来たら同じ会話として続く
      def record_outgoing(character_id:, text:)
        ::ChatSession.record_outgoing(Character.find(character_id), text)
      end

      private

      # 経路（Discord など）は、プラグインがツールを出し分けたり、プロンプトに会話の場所を書いたりするのに使う
      def build_session(character, context = {})
        ::ChatSession.find_or_create(character, character.user, channel: context[:channel], platform: context[:platform])
      end

      # しばらく話しかけられなければ会話を閉じ、振り返って記憶を整理する。
      # 新しい発話があれば、ジョブ側がメッセージ数の違いで見分けて何もしない
      def schedule_timeout(record)
        ::ConversationTimeoutJob
          .set(wait: ::ConversationTimeoutJob::TIMEOUT_MINUTES.minutes)
          .perform_later(record.id, record.message_count)
      end
    end
  end
end
