require "rails_helper"

RSpec.describe Companion::TalkToPetTool do
  let(:mock_gemini) { instance_double(Gemini::Client) }
  let(:character) { create(:character, pet_config: { "name" => "テストペット", "appearance" => "小さな青い鳥", "traits" => "青い羽、小さなくちばし" }) }

  before do
    allow(Gemini::Client).to receive(:new).and_return(mock_gemini)
    allow(mock_gemini).to receive(:chat).and_return(
      Gemini::Response.new({
        "candidates" => [{ "content" => { "parts" => [{ "text" => "きゅるる！" }] } }],
        "usageMetadata" => { "promptTokenCount" => 5, "candidatesTokenCount" => 3, "totalTokenCount" => 8 },
      })
    )
  end

  describe ".execute" do
    it "returns pet response text" do
      result = described_class.execute("こんにちは", llm_client: LlmClient.new(api_key: "test"), character: character)
      expect(result).to eq("きゅるる！")
    end
  end

  describe ".build_prompt" do
    it "includes pet identity when character has pet" do
      prompt = described_class.build_prompt({}, character)
      expect(prompt).to include("テストペット")
      expect(prompt).to include("青い羽")
    end

    it "includes comfort guidance for negative sentiment" do
      prompt = described_class.build_prompt({ sentiment_trend: "negative" }, character)
      expect(prompt).to include("元気がない")
    end

    it "includes curiosity for low diversity" do
      prompt = described_class.build_prompt({ topic_diversity: 0.1 }, character)
      expect(prompt).to include("うずうず")
    end
  end
end
