module Thinking
  # Thinkerの実行結果をパースして保持する
  class ThinkingResult
    attr_reader :all_messages, :summary, :share_message, :next_wakeup_text, :participants

    def initialize(all_messages:, summary:, share_message:, next_wakeup_text:, participants:)
      @all_messages = all_messages
      @summary = summary
      @share_message = share_message
      @next_wakeup_text = next_wakeup_text
      @participants = participants
    end

    def wants_to_share?
      share_message.present?
    end

    # 次の起床時刻をTimeオブジェクトに変換
    def next_wakeup
      return nil unless next_wakeup_text.present?
      parse_wakeup_time(next_wakeup_text)
    end

    # 全メッセージをFL用のテキストに変換
    def to_conversation_text
      all_messages.map { |m|
        role = m[:role] == "user" ? "System" : m[:participant] || "AI"
        "#{role}: #{m[:content]}"
      }.join("\n\n")
    end

    # LLMの最終応答からThinkingResultをパースする
    def self.parse(messages, participants: [:self])
      last_model_msg = messages.reverse.find { |m| m[:role] == "model" }
      return empty_result(messages, participants) unless last_model_msg

      text = last_model_msg[:content].to_s

      # JSON形式での回答を試みる
      json = parse_json(text)
      if json
        new(
          all_messages: messages,
          summary: json["summary"] || json["まとめ"],
          share_message: json["share_message"] || json["共有メッセージ"],
          next_wakeup_text: json["next_wakeup"] || json["次の起床"],
          participants: participants
        )
      else
        # テキスト形式でのパースを試みる
        new(
          all_messages: messages,
          summary: extract_section(text, /(?:まとめ|summary)[：:]?\s*(.*?)(?:\n\d|\n\z|\z)/mi),
          share_message: extract_section(text, /(?:共有|share)[：:]?\s*(.*?)(?:\n\d|\n\z|\z)/mi),
          next_wakeup_text: extract_section(text, /(?:次.*?(?:起|目覚)|next.*?wake)[：:]?\s*(.*?)(?:\n|\z)/mi),
          participants: participants
        )
      end
    end

    def self.empty_result(messages, participants)
      new(
        all_messages: messages,
        summary: nil,
        share_message: nil,
        next_wakeup_text: nil,
        participants: participants
      )
    end

    private

    def parse_wakeup_time(text)
      now = Time.current

      # 「○時間後」「○分後」
      if (match = text.match(/(\d+)\s*時間後/))
        return now + match[1].to_i.hours
      end
      if (match = text.match(/(\d+)\s*分後/))
        return now + match[1].to_i.minutes
      end

      # 「明日の朝」「明日の○時」
      if text.match?(/明日の朝/)
        return (now + 1.day).change(hour: 7)
      end
      if (match = text.match(/明日.*?(\d{1,2})時/))
        return (now + 1.day).change(hour: match[1].to_i)
      end

      # 「○時」（今日）
      if (match = text.match(/(\d{1,2})時/))
        target = now.change(hour: match[1].to_i)
        target += 1.day if target < now
        return target
      end

      # パースできなければnil
      nil
    end

    def self.parse_json(text)
      json_match = text.match(/```json\s*(.*?)\s*```/m)
      json_str = json_match ? json_match[1] : nil
      return nil unless json_str
      JSON.parse(json_str)
    rescue JSON::ParserError
      nil
    end

    def self.extract_section(text, pattern)
      match = text.match(pattern)
      return nil unless match
      result = match[1].strip
      result.empty? ? nil : result
    end
  end
end
