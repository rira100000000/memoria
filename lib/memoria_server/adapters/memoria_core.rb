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
            # クライアントが wants に挙げた capability のうち、返答といっしょに値を返すもの（表情など）
            session.add_reply_capabilities(MemoriaServer::Capability.resolve_many(context.dig(:x_memoria, :wants)))
            # claude -p は返答を最後にまとめて返す。ツールを使う前に書いた文（「調べてみるね」など）と、
            # 続けて動くときの途中の返答は、そのつど区切りの付いたメッセージとして先に返す
            result = session.send_message(input, on_progress: ->(text) {
              yielder << { delta: text }
              yielder << { message_break: true }
            })
            yielder << { delta: result[:response] }
            yielder << { x_memoria: result[:extras] } if result[:extras].present?
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

      # 伝える予定で起きたとき、ユーザーと話している最中なら、思考ループではなくその会話の続きとして話す。
      # 思考ループは会話の一部しか見ないので、会話で言ったことを繰り返したり、済んだ話を始め直したりする
      def wake(character_id:, wakeup: nil)
        character = Character.find(character_id)
        session = wakeup && wakeup[:action] == "share" && conversation_for_event(character)
        return ::Thinking::Wake.run(character, wakeup: wakeup) unless session

        raise MemoriaServer::WakeSkipped, ::Thinking::Wake::BUDGET_EXCEEDED unless ::ApiBudget.can_spend?(character.user, "thinking_loop")

        begin
          result = session.send_event("起きた理由: #{wakeup[:purpose]}")
        rescue ::ClaudeCli::Error => e
          raise MemoriaServer::WakeSkipped, "claude -p が使えませんでした（#{e.message}）"
        end
        schedule_timeout(session.record)
        { share_message: result[:response].presence, summary: nil, recorded: true }
      end

      def recall(character_id:, query:)
        return nil if query.to_s.strip.empty?

        core = ::MemoriaCore::Core.new(Character.find(character_id).vault_path)
        embedding_store = ::MemoriaCore::EmbeddingStore.new(core.vault, ::LlmClient.new)
        embedding_store.initialize!
        result = ::MemoriaCore::ContextRetriever.new(core.vault, embedding_store).retrieve(query)
        result[:retrieved_items].present? ? result[:llm_context_prompt] : nil
      end

      def memorize(character_id:, text:, source:, metadata: {})
        ::MemorizeService.run(Character.find(character_id), text: text, source: source, metadata: metadata).present?
      end

      # 送った連絡を会話の履歴に入れる。返事が来たら同じ会話として続く
      def record_outgoing(character_id:, text:)
        ::ChatSession.record_outgoing(Character.find(character_id), text)
      end

      private

      # 続いている会話。claude -p で話していないときは、出来事を会話の中で受けられないので nil
      def conversation_for_event(character)
        record = ::ChatSessionRecord.active.find_by(character: character, user: character.user)
        return nil unless record

        # 起きて話したことは連絡手段（Discord）に届くので、Discord で話しているときと同じツールを使う
        session = ::ChatSession.new(character, record: record, trigger_type: "thinking_loop", platform: :discord)
        session.use_claude_cli? ? session : nil
      end

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
