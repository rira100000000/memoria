module Thinking
  # memoria_core アダプタの起床（MemoriaServer::Adapter#wake）の実装。
  # 今の状況を集めて考え、体験を記憶に残し、伝えたいことを返す。
  # 予定の進め方・やり直し・連絡手段への送信は memoria（ThinkingLoopJob）が持つ
  class Wake
    BUDGET_EXCEEDED = "今日のAPI予算を使い切っていたため、動けませんでした。".freeze

    # @param wakeup [Hash, nil] MemoriaServer::Adapter#wake の wakeup
    # @return [Hash] { share_message:, summary: }
    def self.run(character, wakeup: nil)
      new(character, wakeup).run
    end

    def initialize(character, wakeup)
      @character = character
      @wakeup = wakeup
    end

    def run
      raise MemoriaServer::WakeSkipped, BUDGET_EXCEEDED unless ApiBudget.can_spend?(@character.user, "thinking_loop")

      core = MemoriaCore::Core.new(@character.vault_path)
      health = Thinking::ThoughtHealthMonitor.report(core)

      # 今の状況を集める（予定の目的も含める）
      snapshot = Thinking::SnapshotBuilder.build(core, @character, health)
      snapshot += wakeup_context if @wakeup

      llm_client = LlmClient.new(usage_tracker: usage_tracker)
      result = think(snapshot: snapshot, core: core, health: health, llm_client: llm_client)

      # 体験を記憶として残す（記憶に残さない予定は省く）
      save_as_memory(result, llm_client) unless @wakeup && !@wakeup[:remember]

      Rails.logger.info("[Thinking::Wake] Character##{@character.id} completed. Summary: #{result.summary}")
      { share_message: result.share_message.presence, summary: result.summary.presence }
    end

    private

    def think(snapshot:, core:, health:, llm_client:)
      Thinking::Thinker.run(snapshot: snapshot, character: @character, core: core, health: health, llm_client: llm_client)
    rescue ClaudeCli::Error => e
      # 利用枠切れなどはやり直しても同じ。予定なしの思考ループは知らせる手段がほかにないので、ここで知らせる
      ClaudeCli.notify_failure(@character, e, what: "思考ループを実行") unless @wakeup
      raise MemoriaServer::WakeSkipped, "claude -p が使えませんでした（#{e.message}）"
    end

    def wakeup_context
      text = +"\n\n今回起きた理由: #{@wakeup[:purpose]}"
      text << "\n予定していた行動: #{@wakeup[:action]}" if @wakeup[:action].present?
      text << "\nこれは繰り返しの予定です（#{@wakeup[:recurrence]}）。" if @wakeup[:recurrence].present?
      if @wakeup[:action] == "share"
        text << "\nこの予定ではマスターに必ず伝えることになっています。share_message に伝える内容を書いてください。"
      end
      due_at = @wakeup[:due_at]
      late = due_at ? Time.current - due_at : 0
      if late > 5.minutes
        text << "\n予定の#{format_time(due_at)}より#{(late / 60).round}分遅れて起きました（サーバが止まっていた可能性があります）。"
      end
      text
    end

    def format_time(time)
      time.in_time_zone(ScheduledWakeup::TIME_ZONE).strftime("%m/%d %H:%M")
    end

    def save_as_memory(result, llm_client)
      MemorizeService.run(@character, text: result.to_conversation_text, source: "autonomous",
        metadata: { participants: result.participants.map(&:to_s) }, llm_client: llm_client)
    end

    def usage_tracker
      character = @character
      lambda { |model, usage|
        begin
          ApiUsageLog.record!(
            user: character.user,
            character: character,
            trigger_type: "thinking_loop",
            llm_model: model,
            usage: usage
          )
        rescue => e
          Rails.logger.warn("[Thinking::Wake] Usage tracking failed: #{e.message}")
        end
      }
    end
  end
end
