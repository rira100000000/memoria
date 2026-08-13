module Thinking
  # Thinkerの実行結果をパースして保持する
  class ThinkingResult
    attr_reader :all_messages, :summary, :share_message, :participants, :reading_occurred

    def initialize(all_messages:, summary:, share_message:, participants:, reading_occurred: false)
      @all_messages = all_messages
      @summary = summary
      @share_message = share_message
      @participants = participants
      @reading_occurred = reading_occurred
    end

    def wants_to_share?
      share_message.present?
    end

    # 全メッセージをFL用のテキストに変換
    def to_conversation_text
      all_messages.map { |m|
        role = m[:participant] || (m[:role] == "user" ? "System" : "AI")
        "#{role}: #{m[:content]}"
      }.join("\n\n")
    end

    # LLMの最終応答からThinkingResultをパースする
    def self.parse(messages, participants: [:self], reading_occurred: false)
      last_model_msg = messages.reverse.find { |m| m[:role] == "model" }
      return empty_result(messages, participants, reading_occurred) unless last_model_msg

      text = last_model_msg[:content].to_s

      json = parse_json(text)
      if json
        new(
          all_messages: messages,
          summary: json["summary"] || json["まとめ"],
          share_message: json["share_message"] || json["共有メッセージ"],
          participants: participants,
          reading_occurred: reading_occurred
        )
      else
        new(
          all_messages: messages,
          summary: extract_section(text, /(?:まとめ|summary)[：:]?\s*(.*?)(?:\n\d|\n\z|\z)/mi),
          share_message: extract_section(text, /(?:共有|share)[：:]?\s*(.*?)(?:\n\d|\n\z|\z)/mi),
          participants: participants,
          reading_occurred: reading_occurred
        )
      end
    end

    def self.empty_result(messages, participants, reading_occurred = false)
      new(all_messages: messages, summary: nil, share_message: nil, participants: participants, reading_occurred: reading_occurred)
    end

    private

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
