module MemoriaServer
  # プラグインが宣言した定期の起床（Plugin#routines）を、予定（ScheduledWakeup）にそろえる。
  # ジョブのプロセスの起動時に呼ぶ（bin/jobs）。何度呼んでも同じ結果になる。
  module Routines
    module_function

    # @return [Hash] { created: [], updated: [], rescheduled: [], cancelled: [] }（予定のIDの配列）
    def sync!(characters = Character.all)
      report = { created: [], updated: [], rescheduled: [], cancelled: [] }
      characters.each { |character| sync_character(character, report) }
      report
    end

    def sync_character(character, report)
      declared = Plugin.routines_for(character).map { |plugin, routine| normalize(plugin, routine) }.compact
      keys = declared.map { |r| r[:key] }

      declared.each do |routine|
        wakeup = character.scheduled_wakeups.find_or_initialize_by(routine_key: routine[:key])
        new_record = wakeup.new_record?
        reschedule = new_record || wakeup.status != "pending" || wakeup.recurrence != routine[:recurrence]

        wakeup.assign_attributes(
          purpose: routine[:purpose],
          action: routine[:action],
          remember: routine[:remember],
          destination: routine[:to],
          recurrence: routine[:recurrence],
          origin: "user"  # キャラの持ち主が入れたプラグインの宣言なので、頼まれた予定と同じく失敗を必ず知らせる
        )
        if reschedule
          wakeup.status = "pending"
          wakeup.scheduled_at = ScheduledWakeup.parse_recurrence(routine[:recurrence]).next_time.to_t.in_time_zone
        end
        next unless wakeup.changed?

        wakeup.save!
        wakeup.enqueue! if reschedule
        report[new_record ? :created : (reschedule ? :rescheduled : :updated)] << wakeup.id
      end

      character.scheduled_wakeups.pending.where.not(routine_key: nil).where.not(routine_key: keys).find_each do |wakeup|
        wakeup.cancel!
        report[:cancelled] << wakeup.id
      end
    end

    def normalize(plugin, routine)
      routine = routine.to_h.symbolize_keys
      key = "#{plugin.name}:#{routine[:key]}"
      unless routine[:key].present? && routine[:purpose].present? && ScheduledWakeup.parse_recurrence(routine[:recurrence])
        Rails.logger.error("[MemoriaServer::Routines] #{key}: key・purpose・recurrence（cron式）が必要です")
        return nil
      end

      {
        key: key,
        recurrence: routine[:recurrence].to_s,
        purpose: routine[:purpose].to_s,
        action: routine[:action].presence,
        remember: routine[:remember] == true,
        to: routine[:to].presence&.to_s,
      }
    end
  end
end
