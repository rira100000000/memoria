module MemoriaServer
  module Plugins
    # add_schedule の time（日時の指定）を時刻にする。日時はアプリのタイムゾーン（Asia/Tokyo）で読む
    #
    # 受け付ける形:
    #   相対:     "30分後", "3時間後", "1時間30分後", "3日後"（今からちょうど3日後）, "3日後の12時"
    #   日付の語: "今日 21:00", "明日の朝", "明日 14:23", "明後日の15時半"
    #   絶対:     "2026-10-29 12:00", "2026/10/29 12:00", "10/29 12:00", "10月29日 12時", ISO 8601
    #   時刻だけ: "21:00", "9時", "午後3時"（過ぎていれば翌日）
    # 日付を指定して時刻がないとき（"明日" だけなど）は、いつにするか決めずに Error にする
    module ScheduleTime
      class Error < StandardError; end

      DAY_WORDS = { "明後日" => 2, "あさって" => 2, "明日" => 1, "あした" => 1, "今日" => 0, "本日" => 0 }.freeze
      PARTS_OF_DAY = { "夕方" => 17, "朝" => 7, "昼" => 12, "夜" => 21 }.freeze
      AFTERNOON = /午後|夕方|(?<!深)夜(?!中)|pm/i

      module_function

      # @return [ActiveSupport::TimeWithZone, nil] 読めなかったら nil
      # @raise [Error] 読めたが時刻が足りない・おかしいとき
      def parse(text, now: Time.current)
        text = text.to_s.unicode_normalize(:nfkc).strip
        return nil if text.empty?

        iso8601(text) || relative(text, now) || absolute(text, now) || with_day_word(text, now) || clock_only(text, now)
      end

      def iso8601(text)
        return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}T/)

        Time.zone.iso8601(text)
      rescue ArgumentError
        nil
      end

      def relative(text, now)
        if (match = text.match(/(\d+)\s*日後/))
          days = match[1].to_i
          clock = clock_in(text.sub(match[0], ""))
          return clock ? at(now.to_date + days, clock) : now + days.days
        end
        if (match = text.match(/(\d+)\s*時間\s*(?:(\d+)\s*分)?\s*後/))
          return now + match[1].to_i.hours + match[2].to_i.minutes
        end
        if (match = text.match(/(\d+)\s*分\s*後/))
          return now + match[1].to_i.minutes
        end

        nil
      end

      def absolute(text, now)
        if (match = text.match(%r{(\d{4})\s*[-/年]\s*(\d{1,2})\s*[-/月]\s*(\d{1,2})\s*日?}))
          date = build_date(match[1].to_i, match[2].to_i, match[3].to_i)
        elsif (match = text.match(%r{(\d{1,2})\s*[/月]\s*(\d{1,2})\s*日?}))
          date = build_date(now.year, match[1].to_i, match[2].to_i)
          # 年を書いていない日付は近いほうの年にする（12月に「1/3」と書けば翌年）
          date = date.next_year if date < now.to_date - 180
        else
          return nil
        end

        at(date, require_clock(text.sub(match[0], ""), text))
      end

      def with_day_word(text, now)
        word, days = DAY_WORDS.find { |w, _| text.include?(w) }
        return nil unless word

        at(now.to_date + days, require_clock(text.sub(word, ""), text))
      end

      def clock_only(text, now)
        clock = clock_in(text)
        return nil unless clock

        target = at(now.to_date, clock)
        target += 1.day if target <= now
        target
      end

      # 時刻の部分を [時, 分] にする。時刻が書かれていなければ nil
      def clock_in(text)
        hour, min =
          if (match = text.match(/(\d{1,2})\s*:\s*(\d{2})/))
            [match[1].to_i, match[2].to_i]
          elsif (match = text.match(/(\d{1,2})\s*時(?!間)\s*(?:(\d{1,2})\s*分|(半))?/))
            [match[1].to_i, match[3] ? 30 : match[2].to_i]
          elsif (word = PARTS_OF_DAY.keys.find { |w| text.include?(w) })
            return [PARTS_OF_DAY[word], 0]
          end
        return nil unless hour

        hour += 12 if hour < 12 && text.match?(AFTERNOON)
        raise Error, "時刻がおかしいです: #{text}" unless (0..23).cover?(hour) && (0..59).cover?(min)

        [hour, min]
      end

      def require_clock(rest, text)
        clock_in(rest) || raise(Error, "時刻も指定してください: #{text}（例: '明日 9:00', '2026-10-29 12:00'）")
      end

      def build_date(year, month, day)
        Date.new(year, month, day)
      rescue Date::Error
        raise Error, "日付がおかしいです: #{year}-#{month}-#{day}"
      end

      def at(date, clock)
        Time.zone.local(date.year, date.month, date.day, clock[0], clock[1])
      end
    end
  end
end
