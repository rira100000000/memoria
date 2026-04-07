require "rails_helper"

RSpec.describe Thinking::ThinkingResult do
  describe ".parse" do
    it "parses JSON response" do
      messages = [{
        role: "model",
        content: '```json
{"summary": "テスト完了", "share_message": "マスターに報告"}
```',
      }]

      result = described_class.parse(messages)
      expect(result.summary).to eq("テスト完了")
      expect(result.share_message).to eq("マスターに報告")
      expect(result.wants_to_share?).to be true
    end

    it "handles null share_message" do
      messages = [{
        role: "model",
        content: '```json
{"summary": "静かに過ごした", "share_message": null}
```',
      }]

      result = described_class.parse(messages)
      expect(result.summary).to eq("静かに過ごした")
      expect(result.wants_to_share?).to be false
    end

    it "returns empty result for no model messages" do
      result = described_class.parse([{ role: "tool", content: "test" }])
      expect(result.summary).to be_nil
      expect(result.wants_to_share?).to be false
    end

    it "passes through reading_occurred flag" do
      messages = [{ role: "model", content: '```json
{"summary": "読書した", "share_message": null}
```' }]

      result = described_class.parse(messages, reading_occurred: true)
      expect(result.reading_occurred).to be true
    end

    it "defaults reading_occurred to false" do
      messages = [{ role: "model", content: '```json
{"summary": "test", "share_message": null}
```' }]

      result = described_class.parse(messages)
      expect(result.reading_occurred).to be false
    end
  end

  describe "#to_conversation_text" do
    it "formats messages for FL" do
      result = described_class.new(
        all_messages: [
          { role: "model", content: "考え中", participant: "テスト" },
          { role: "tool", content: "検索結果", participant: "system" },
        ],
        summary: "test",
        share_message: nil,
        participants: [:self]
      )

      text = result.to_conversation_text
      expect(text).to include("テスト: 考え中")
      expect(text).to include("system: 検索結果")
    end
  end
end
