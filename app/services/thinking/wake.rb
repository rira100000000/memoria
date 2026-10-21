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
      save_as_memory(core, result, llm_client) unless @wakeup && !@wakeup[:remember]

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

    def save_as_memory(core, result, llm_client)
      conversation_text = result.to_conversation_text
      return if conversation_text.strip.empty?

      # FL(FullLog)は常に保存
      fl_store = core.fl_store
      fl_path = fl_store.create(@character.name)
      fl_store.append(fl_path, conversation_text)

      fl_store.update_frontmatter(fl_path, {
        "source" => "autonomous",
        "participants" => result.participants.map(&:to_s),
      })

      # 読書が含まれるloopではSN生成を抑制（感想はReadingProgressに蓄積済み）
      if result.reading_occurred
        generate_reading_summary_if_completed(llm_client, core)
        return
      end

      # 読書を含まないloopは従来通りSN生成
      service = ReflectionService.new(@character, llm_client: llm_client)
      reflection = service.generate(
        conversation_text: conversation_text,
        full_log_ref: File.basename(fl_path),
        timestamp: Time.now.strftime("%Y%m%d%H%M"),
      )

      process_reflection(reflection, core, @character) if reflection
    end

    def process_reflection(reflection, core, character)
      sn_content = core.vault.read(reflection[:file_path])
      if sn_content
        fm, body = MemoriaCore::Frontmatter.parse(sn_content)
        if fm
          fm["source"] = "autonomous"
          core.vault.write(reflection[:file_path], MemoriaCore::Frontmatter.build(fm, body))
        end
      end

      TagProfilingJob.perform_later(character.id, reflection[:file_path])
    end

    def generate_reading_summary_if_completed(llm_client, core)
      completed = ReadingProgress
        .where(character: @character, status: "completed", summary_generated: false)
        .where.not(reading_notes: [nil, "", "[]"])
        .first
      return unless completed

      # 読書の掛け合いをFullLogに保存
      save_reading_log_as_fl(completed, core)

      # キャラクターのSN生成
      service = Reading::ReadingSummaryService.new(@character, llm_client: llm_client)
      reflection = service.generate_for(completed)
      process_reflection(reflection, core, @character) if reflection

      # トートのSN生成
      generate_companion_reading_summary(completed, llm_client)

      # 統合SN生成済みフラグ（reading_notesは保持）
      completed.update!(summary_generated: true)
    end

    def save_reading_log_as_fl(reading_progress, core)
      companion_name = @character.reading_companion&.name || Reading::ReadingCompanion::NAME

      lines = ["読書記録: #{reading_progress.author}「#{reading_progress.title}」\n"]
      reading_progress.parsed_notes.each do |entry|
        case entry["type"]
        when "narration"
          lines << "【原文】\n#{entry["text"]}\n"
        when "dialogue"
          speaker = entry["speaker"] == "companion" ? companion_name : @character.name
          lines << "#{speaker}: #{entry["text"]}\n"
        end
      end

      fl_store = core.fl_store
      fl_path = fl_store.create(@character.name)
      fl_store.append(fl_path, lines.join("\n"))
      fl_store.update_frontmatter(fl_path, {
        "source" => "reading",
        "participants" => [@character.name, companion_name],
        "work_title" => reading_progress.title,
        "work_author" => reading_progress.author,
      })
    end

    def generate_companion_reading_summary(completed, llm_client)
      tote = Reading::ReadingCompanion.find_character(for_character: completed.character)
      return unless tote

      service = Reading::ReadingSummaryService.new(tote, llm_client: llm_client)
      reflection = service.generate_companion_summary_for(completed, reader_name: completed.character.name)
      return unless reflection

      tote_core = MemoriaCore::Core.new(tote.vault_path)
      process_reflection(reflection, tote_core, tote)
    rescue => e
      Rails.logger.warn("[Thinking::Wake] Companion summary failed: #{e.message}")
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
