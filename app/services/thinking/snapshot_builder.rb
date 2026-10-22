module Thinking
  # LLMに渡す「今の状況」テキストを組み立てる
  # API不要、Rubyロジックのみ。アプリ層の責務
  class SnapshotBuilder
    # 続いている会話から渡すやりとりの数と、1件あたりの文字数
    RECENT_MESSAGES = 10
    RECENT_MESSAGE_CHARS = 300

    def self.build(core, character, health)
      lines = []

      # 時間帯
      now = Time.current
      period = time_period_label(now)
      lines << "現在時刻: #{now.strftime('%Y-%m-%d %H:%M')}（#{period}）"

      # ユーザーとの会話状況
      lines << "前回マスターと話した時間: #{core.last_user_conversation_age}"
      lines << "前回マスターと話した話題: #{core.last_user_conversation_topic}"

      # 続いている会話（まだ振り返りになっていないので、上の「前回の話題」には入っていない）
      recent = recent_conversation(character)
      if recent.any?
        lines << "いま続いているマスターとの会話（直近#{recent.size}件、古い順）:"
        recent.each { |line| lines << "  #{line}" }
      end

      # 前回の自律活動
      autonomous_summary = core.last_autonomous_log_summary
      if autonomous_summary
        lines << "前回の自分の活動: #{autonomous_summary}"
      else
        lines << "前回の自分の活動: まだ自律的な活動の記録はありません"
      end

      # 前回の続き
      continuation = core.pending_continuation
      if continuation
        lines << "前回の続き: 「#{continuation[:topic]}」で以下が未完了"
        continuation[:items].each { |item| lines << "  - #{item}" }
      end

      # 健全性情報（参考として提供、判断はAI自身）
      if health[:sample_count] && health[:sample_count] >= 3
        if health[:topic_diversity] && health[:topic_diversity] < 0.3
          lines << "（参考: 最近同じトピックについて繰り返し考えています）"
        end

        if health[:external_input_ratio] && health[:external_input_ratio] < 0.2
          lines << "（参考: 最近は外部からの新しい情報に触れていません）"
        end

        if health[:max_continuation_chain] && health[:max_continuation_chain] > 3
          lines << "（参考: 「続きをやろう」が#{health[:max_continuation_chain]}回連続しています）"
        end
      end

      # 今後のスケジュール
      upcoming = character.scheduled_wakeups.upcoming.limit(5)
      if upcoming.any?
        lines << ""
        lines << "今後の予定:"
        upcoming.each do |s|
          lines << "  #{s.summary_line}"
        end
      end

      lines.join("\n")
    end

    def self.recent_conversation(character)
      record = ChatSessionRecord.active.where(character: character).order(last_message_at: :desc).first
      return [] unless record

      Array(record.messages).last(RECENT_MESSAGES).map do |m|
        speaker = m["role"] == "user" ? "マスター" : character.name
        "#{speaker}: #{m["content"].to_s.squish.truncate(RECENT_MESSAGE_CHARS, omission: "…")}"
      end
    end

    def self.time_period_label(time)
      case time.hour
      when 5..10 then "朝"
      when 11..13 then "昼"
      when 14..17 then "午後"
      when 18..20 then "夕方"
      when 21..23 then "夜"
      else "深夜"
      end
    end
  end
end
