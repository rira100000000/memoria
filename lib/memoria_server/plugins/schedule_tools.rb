require_relative "schedule_time"

module MemoriaServer
  module Plugins
    # 予定のプラグイン（Schedule）のツール
    # キャラクターが自分の予定を確認・追加・削除できる
    class ScheduleTools
      MINIMUM_INTERVAL = 10.minutes

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
            description: "新しいスケジュールを追加する。単発なら time、毎日・毎週など繰り返すなら repeat を指定する。" \
              "日時はすべて日本時間（Asia/Tokyo）。登録された日時は結果の scheduled_at で確かめる。",
            parameters: {
              type: "OBJECT",
              properties: {
                time: {
                  type: "STRING",
                  description: "単発の予定のとき、いつ。日本時間（Asia/Tokyo）。書ける形: " \
                    "相対（'30分後', '3時間後', '3日後'=今からちょうど3日後, '3日後の12時'）、" \
                    "日付の語と時刻（'明日 14:23', '明日の朝'=7時, '明後日の15時半', '今日 21:00'）、" \
                    "日時そのもの（'2026-10-29 12:00', '10/29 12:00', '10月29日 12時'）、" \
                    "時刻だけ（'21:00', '午後3時'。過ぎていれば翌日）。" \
                    "日付を書くときは時刻も書く。過ぎた日時は登録できない。先の日時は何日後でも指定どおりに入る",
                },
                repeat: { type: "STRING", description: "繰り返しの予定のとき、cron式（例: '0 7 * * *'=毎朝7時, '0 9 * * 1'=毎週月曜9時）。時刻は日本時間。最短間隔は1時間" },
                purpose: { type: "STRING", description: "なぜ起きるか（例: 'ユーザーに朝の挨拶', '作業リマインダー'）" },
                action: { type: "STRING", description: "何をするか（'share'=ユーザーに必ず伝える, 'think'=自由に考える, 省略=自由）" },
                remember: { type: "BOOLEAN", description: "実行したことを記憶に残すか（省略時: 単発は残す、繰り返しは残さない）" },
                to: { type: "STRING", description: "伝えることの種類。それを受け持つチャンネルに送る（使える種類はシステムプロンプトの「予定の送り先」）。省略すると既定のチャンネル" },
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
          }
        ]

        unless autonomous
          fns << {
            name: "approve_schedule",
            description: "承認待ちになっている繰り返しの予定を、ユーザーの承認を受けて有効にする。ユーザーが承認を明言したときだけ使う",
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
            repeat: args["repeat"], remember: args["remember"], to: args["to"], autonomous: autonomous)
        when "cancel_schedule"
          cancel(character, args["schedule_id"], only_next: args["only_next"])
        when "approve_schedule"
          return { error: "繰り返しの予定はユーザーの承認が必要です。自分では承認できません" } if autonomous

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

      def self.add(character, time_text:, purpose:, action: nil, repeat: nil, remember: nil, to: nil, autonomous: false)
        if repeat.present?
          return add_recurring(character, repeat: repeat, purpose: purpose, action: action,
            remember: remember, to: to, autonomous: autonomous)
        end
        return { error: "time か repeat のどちらかを指定してください" } if time_text.blank?

        begin
          wakeup_at = ScheduleTime.parse(time_text)
        rescue ScheduleTime::Error => e
          return { error: e.message }
        end
        return { error: "時間を解釈できませんでした: #{time_text}（例: '3時間後', '明日 14:00', '2026-10-29 12:00'）" } unless wakeup_at
        if wakeup_at <= Time.current
          return { error: "過ぎた日時です: #{time_text}（#{format_time(wakeup_at)}。今は #{format_time(Time.current)}）" }
        end

        # ガードレール（自律行動は最短10分、ユーザー指示は最短1分）。先のほうには上限を設けない
        min_interval = autonomous ? MINIMUM_INTERVAL : 1.minute
        clamped = [wakeup_at, min_interval.from_now].max

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
          destination: to.presence,
          status: "pending",
          origin: autonomous ? "self" : "user",
          remember: remember.nil? ? true : remember
        )

        # 思考ループをスケジュール
        wakeup.enqueue!

        result = {
          success: true,
          schedule_id: wakeup.id,
          scheduled_at: format_time(clamped),
          purpose: purpose,
        }
        if clamped - wakeup_at > 1.minute
          result[:note] = "指定の #{format_time(wakeup_at)} は近すぎる（#{autonomous ? "10分" : "1分"}後より前）ので、#{format_time(clamped)} にした"
        end
        result
      end

      def self.add_recurring(character, repeat:, purpose:, action:, remember:, autonomous:, to: nil)
        cron = ScheduledWakeup.parse_recurrence(repeat)
        return { error: "繰り返しを解釈できませんでした: #{repeat}（cron式で指定してください。例: '0 7 * * *'）" } unless cron
        if cron.rough_frequency < ScheduledWakeup::MIN_RECURRING_INTERVAL
          return { error: "繰り返しの間隔が短すぎます（最短1時間）: #{repeat}" }
        end

        if character.scheduled_wakeups.where(status: %w[pending proposed], recurrence: cron.original).exists?
          return { error: "同じ繰り返しの予定が既にあります: #{cron.original}" }
        end

        # キャラが自分で入れた繰り返しは、ずっと予算を使い続けるので既定では承認制にする（プラグインで外せる）
        needs_approval = autonomous && MemoriaServer::Plugin.schedule_policy(character)[:self_recurring_needs_approval]
        wakeup = character.scheduled_wakeups.create!(
          scheduled_at: cron.next_time(Time.current).to_t,
          recurrence: cron.original,
          purpose: purpose,
          action: action,
          destination: to.presence,
          status: needs_approval ? "proposed" : "pending",
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
          status: wakeup.status == "proposed" ? "ユーザーの承認待ち（承認されるまで動きません）" : "有効",
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

      private_class_method def self.format_time(time)
        time.in_time_zone("Asia/Tokyo").strftime("%Y-%m-%d %H:%M")
      end
    end
  end
end
