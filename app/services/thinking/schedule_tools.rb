module Thinking
  # Thinker用のスケジュール管理ツール
  # AIが自分のスケジュールを確認・追加・削除できる
  class ScheduleTools
    MINIMUM_INTERVAL = 10.minutes
    MAXIMUM_INTERVAL = 7.days

    def self.definitions
      {
        functionDeclarations: [
          {
            name: "list_schedules",
            description: "自分の今後のスケジュール一覧を確認する",
            parameters: { type: "OBJECT", properties: {} },
          },
          {
            name: "add_schedule",
            description: "新しいスケジュールを追加する。目覚める時間と目的を指定する。",
            parameters: {
              type: "OBJECT",
              properties: {
                time: { type: "STRING", description: "いつ（例: '3時間後', '明日の朝8時', '21:00'）" },
                purpose: { type: "STRING", description: "なぜ起きるか（例: 'マスターに朝の挨拶', '作業リマインダー'）" },
                action: { type: "STRING", description: "何をするか（'share'=マスターに伝える, 'think'=自由に考える, 省略=自由）" },
              },
              required: ["time", "purpose"],
            },
          },
          {
            name: "cancel_schedule",
            description: "スケジュールをキャンセルする",
            parameters: {
              type: "OBJECT",
              properties: {
                schedule_id: { type: "INTEGER", description: "キャンセルするスケジュールのID" },
              },
              required: ["schedule_id"],
            },
          },
        ],
      }
    end

    # @param autonomous [Boolean] 自律行動からの呼び出しか（trueなら最短10分制限）
    def self.execute(name, args, character:, autonomous: false)
      case name
      when "list_schedules"
        list(character)
      when "add_schedule"
        add(character, time_text: args["time"], purpose: args["purpose"], action: args["action"], autonomous: autonomous)
      when "cancel_schedule"
        cancel(character, args["schedule_id"])
      end
    end

    def self.list(character)
      schedules = character.scheduled_wakeups.upcoming.limit(20)
      if schedules.empty?
        { schedules: "予定はありません" }
      else
        items = schedules.map { |s|
          "ID:#{s.id} #{s.scheduled_at.in_time_zone('Asia/Tokyo').strftime('%m/%d %H:%M')} — #{s.purpose}#{s.action ? " [#{s.action}]" : ""}"
        }
        { schedules: items.join("\n") }
      end
    end

    def self.add(character, time_text:, purpose:, action: nil, autonomous: false)
      wakeup_at = parse_time(time_text)
      return { error: "時間を解釈できませんでした: #{time_text}" } unless wakeup_at

      # ガードレール（自律行動は最短10分、ユーザー指示は最短1分）
      min_interval = autonomous ? MINIMUM_INTERVAL : 1.minute
      clamped = wakeup_at.clamp(min_interval.from_now, MAXIMUM_INTERVAL.from_now)

      # 近接時間帯（±5分）に既存の予定があれば重複として拒否
      nearby = character.scheduled_wakeups.pending
        .where(scheduled_at: (clamped - 5.minutes)..(clamped + 5.minutes))
      if nearby.exists?
        existing = nearby.first
        return {
          error: "近い時間に既に予定があります（ID:#{existing.id} #{existing.scheduled_at.in_time_zone('Asia/Tokyo').strftime('%H:%M')} #{existing.purpose}）",
        }
      end

      wakeup = character.scheduled_wakeups.create!(
        scheduled_at: clamped,
        purpose: purpose,
        action: action,
        status: "pending"
      )

      # 思考ループをスケジュール
      ThinkingLoopJob.set(wait_until: clamped).perform_later(character.id, wakeup.id)

      {
        success: true,
        schedule_id: wakeup.id,
        scheduled_at: clamped.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
        purpose: purpose,
      }
    end

    def self.cancel(character, schedule_id)
      wakeup = character.scheduled_wakeups.pending.find_by(id: schedule_id)
      return { error: "スケジュールが見つかりません: ID #{schedule_id}" } unless wakeup

      wakeup.cancel!
      { success: true, cancelled_id: schedule_id, purpose: wakeup.purpose }
    end

    private_class_method def self.parse_time(text)
      now = Time.current

      if (match = text.match(/(\d+)\s*時間後/))
        return now + match[1].to_i.hours
      end
      if (match = text.match(/(\d+)\s*分後/))
        return now + match[1].to_i.minutes
      end
      if text.match?(/明日の朝/)
        return (now + 1.day).change(hour: 7)
      end
      if (match = text.match(/明日.*?(\d{1,2})時/))
        return (now + 1.day).change(hour: match[1].to_i)
      end
      if (match = text.match(/(\d{1,2}):(\d{2})/))
        target = now.change(hour: match[1].to_i, min: match[2].to_i)
        target += 1.day if target < now
        return target
      end
      if (match = text.match(/(\d{1,2})時/))
        target = now.change(hour: match[1].to_i)
        target += 1.day if target < now
        return target
      end

      nil
    end
  end
end
