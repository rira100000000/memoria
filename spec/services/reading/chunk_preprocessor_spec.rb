require "rails_helper"

RSpec.describe Reading::ChunkPreprocessor do
  let(:llm_client) { instance_double(LlmClient) }

  describe ".call" do
    it "returns single chunk for short text" do
      result = described_class.call("短い文章。", llm_client: llm_client)
      expect(result.size).to eq(1)
      expect(result.first["end"]).to eq(5)
    end

    it "parses LLM response into boundaries" do
      text = "あ" * 1000
      allow(llm_client).to receive(:generate).and_return({
        text: '```json
[{"end": 300, "label": "導入"}, {"end": 700, "label": "展開"}, {"end": 1000, "label": "結末"}]
```'
      })

      result = described_class.call(text, llm_client: llm_client)
      expect(result.size).to eq(3)
      expect(result.last["end"]).to eq(1000)
      expect(result.first["label"]).to eq("導入")
    end

    it "falls back to mechanical split on LLM failure" do
      text = "あ" * 1000
      allow(llm_client).to receive(:generate).and_raise(StandardError.new("API error"))

      result = described_class.call(text, llm_client: llm_client)
      expect(result.size).to be >= 1
      expect(result.last["end"]).to eq(1000)
    end

    it "falls back on invalid JSON" do
      text = "あ" * 1000
      allow(llm_client).to receive(:generate).and_return({ text: "invalid json" })

      result = described_class.call(text, llm_client: llm_client)
      expect(result.size).to be >= 1
      expect(result.last["end"]).to eq(1000)
    end
  end
end
