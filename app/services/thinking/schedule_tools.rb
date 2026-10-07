module Thinking
  # Thinker用のスケジュール管理ツール
  # AIが自分のスケジュールを確認・追加・削除できる
  class ScheduleTools
    MINIMUM_INTERVAL = 10.minutes
    MAXIMUM_INTERVAL = 7.days

    # @param autonomous [Boolean] 自律行動向けの定義か（trueなら承認ツールを含めない）
    def self.definitions(autonomous: false)
      fns = [
        {
          name: "list_schedules",
          description: "自分の今後のスケジュール一覧を確認する（繰り返しの予定と承認待ちの提案を含む）",
          parameters: { type: "OBJECT", properties: {} },
        },
        {
          name: "add_schedule",
          description: "新しいスケジュールを追加する。単発なら time、毎日・毎週など繰り返すなら repeat を指定する。",
          parameters: {
            type: "OBJECT",
            properties: {
              time: { type: "STRING", description: "単発の予定のとき、いつ（例: '3時間後', '明日の朝8時', '21:00'）" },
              repeat: { type: "STRING", description: "繰り返しの予定のとき、cron式（例: '0 7 * * *'=毎朝7時, '0 9 * * 1'=毎週月曜9時）。時刻は日本時間。最短間隔は1時間" },
              purpose: { type: "STRING", description: "なぜ起きるか（例: 'マスターに朝の挨拶', '作業リマインダー'）" },
              action: { type: "STRING", description: "何をするか（'share'=マスターに必ず伝える, 'think'=自由に考える, 省略=自由）" },
              remember: { type: "BOOLEAN", description: "実行したことを記憶に残すか（省略時: 単発は残す、繰り返しは残さない）" },
            },
            required: ["purpose"],
          },
        },
        {
          name: "cancel_schedule",
          description: "スケジュールをキャンセルする。繰り返しの予定は only_next=true でこの回だけ飛ばせる",
          parameters: {
            type: "OBJECT",
            properties: {
              schedule_id: { type: "INTEGER", description: "キャンセルするスケジュールのID" },
              only_next: { type: "BOOLEAN", description: "繰り返しの予定で、次の1回だけ飛ばす（ルールは残す）" },
            },
            required: ["schedule_id"],
          },
        },
      ]

      unless autonomous
        fns << {
          name: "approve_schedule",
          description: "承認待ちになっている繰り返しの予定を、マスターの承認を受けて有効にする。マスターが承認を明言したときだけ使う",
          parameters: {
            type: "OBJECT",
            properties: {
              schedule_id: { type: "INTEGER", description: "承認するスケジュールのID" },
            },
            required: ["schedule_id"],
          },
        }
      end

      { functionDeclarations: fns }
    end

    # @param autonomous [Boolean] 自律行動からの呼び出しか（trueなら最短10分制限、繰り返しは承認待ち）
    def self.execute(name, args, character:, autonomous: false)
      case name
      when "list_schedules"
        list(character)
      when "add_schedule"
        add(character, time_text: args["time"], purpose: args["purpose"], action: args["action"],
          repeat: args["repeat"], remember: args["remember"], autonomous: autonomous)
      when "cancel_schedule"
        cancel(character, args["schedule_id"], only_next: args["only_next"])
      when "approve_schedule"
        return { error: "繰り返しの予定はマスターの承認が必要です。自分では承認できません" } if autonomous

        approve(character, args["schedule_id"])
      end
    end

    def self.list(character)
      schedules = character.scheduled_wakeups.upcoming.limit(20).to_a +
        character.scheduled_wakeups.proposed.order(:scheduled_at).to_a
      if schedules.empty?
        { schedules: "予定はありません" }
      else
        items = schedules.map { |s|
          "ID:#{s.id} #{s.summary_line}"
        }
        { schedules: items.join("\n") }
      end
    end

    def self.add(character, time_text:, purpose:, action: nil, repeat: nil, remember: nil, autonomous: false)
      if repeat.present?
        return add_recurring(character, repeat: repeat, purpose: purpose, action: action,
          remember: remember, autonomous: autonomous)
      end
      return { error: "time か repeat のどちらかを指定してください" } if time_text.blank?

      wakeup_at = parse_time(time_text)
      return { error: "時間を解釈できませんでした: #{time_text}" } unless wakeup_at

      # ガードレール（自律行動は最短10分、ユーザー指示は最短1分）
      min_interval = autonomous ? MINIMUM_INTERVAL : 1.minute
      clamped = wakeup_at.clamp(min_interval.from_now, MAXIMUM_INTERVAL.from_now)

      # 近接時間帯（±5分）に既存の単発の予定があれば重複として拒否
      # 繰り返しの予定とは比べない（毎朝7時の予定があっても「明日の朝」を入れられるように）
      nearby = character.scheduled_wakeups.pending.one_shot
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
        status: "pending",
        origin: autonomous ? "self" : "user",
        remember: remember.nil? ? true : remember
      )

      # 思考ループをスケジュール
      wakeup.enqueue!

      {
        success: true,
        schedule_id: wakeup.id,
        scheduled_at: clamped.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
        purpose: purpose,
      }
    end

    def self.add_recurring(character, repeat:, purpose:, action:, remember:, autonomous:)
      cron = ScheduledWakeup.parse_recurrence(repeat)
      return { error: "繰り返しを解釈できませんでした: #{repeat}（cron式で指定してください。例: '0 7 * * *'）" } unless cron
      if cron.rough_frequency < ScheduledWakeup::MIN_RECURRING_INTERVAL
        return { error: "繰り返しの間隔が短すぎます（最短1時間）: #{repeat}" }
      end

      if character.scheduled_wakeups.where(status: %w[pending proposed], recurrence: cron.original).exists?
        return { error: "同じ繰り返しの予定が既にあります: #{cron.original}" }
      end

      wakeup = character.scheduled_wakeups.create!(
        scheduled_at: cron.next_time(Time.current).to_t,
        recurrence: cron.original,
        purpose: purpose,
        action: action,
        # キャラが自分で入れた繰り返しは、ずっと予算を使い続けるので承認制にする
        status: autonomous ? "proposed" : "pending",
        origin: autonomous ? "self" : "user",
        remember: remember.nil? ? false : remember
      )

      if wakeup.status == "proposed"
        MessageDispatcher.dispatch(character,
          "📝 #{character.name}が繰り返しの予定を提案しました: #{wakeup.summary_line(with_id: true)}\n" \
          "有効にするなら、#{character.name}に承認すると伝えてください。")
      else
        wakeup.enqueue!
      end

      {
        success: true,
        schedule_id: wakeup.id,
        next_at: wakeup.scheduled_at.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
        recurrence: wakeup.recurrence,
        purpose: purpose,
        status: wakeup.status == "proposed" ? "マスターの承認待ち（承認されるまで動きません）" : "有効",
      }
    end

    def self.cancel(character, schedule_id, only_next: false)
      wakeup = character.scheduled_wakeups.where(status: %w[pending proposed]).find_by(id: schedule_id)
      return { error: "スケジュールが見つかりません: ID #{schedule_id}" } unless wakeup

      if only_next
        return { error: "この回だけ飛ばせるのは、有効な繰り返しの予定だけです" } unless wakeup.recurring? && wakeup.status == "pending"

        skipped_at = wakeup.scheduled_at
        wakeup.advance!(from: skipped_at)
        return {
          success: true,
          skipped: skipped_at.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
          next_at: wakeup.scheduled_at.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
          purpose: wakeup.purpose,
        }
      end

      wakeup.cancel!
      { success: true, cancelled_id: schedule_id, purpose: wakeup.purpose }
    end

    def self.approve(character, schedule_id)
      wakeup = character.scheduled_wakeups.proposed.find_by(id: schedule_id)
      return { error: "承認待ちの予定が見つかりません: ID #{schedule_id}" } unless wakeup

      wakeup.approve!
      {
        success: true,
        approved_id: wakeup.id,
        next_at: wakeup.scheduled_at.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M"),
        purpose: wakeup.purpose,
      }
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
