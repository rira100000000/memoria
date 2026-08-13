require "rails_helper"

RSpec.describe Reading::TalkToCompanionTool do
  let(:llm_client) { instance_double(LlmClient) }

  describe ".definition" do
    it "includes talk_to_reading_companion" do
      names = described_class.definition[:functionDeclarations].map { |f| f[:name] }
      expect(names).to include("talk_to_reading_companion")
    end
  end

  describe ".execute" do
    let(:character) { create(:character, reading_enabled: true) }

    it "returns error when not reading" do
      result = described_class.execute("test", llm_client: llm_client, character: character)
      expect(result[:error]).to include("読書中")
    end

    it "returns companion response when reading" do
      create(:reading_progress, character: character, status: "reading")
      allow(llm_client).to receive(:generate).and_return({ text: "いい感想だね。" })

      result = described_class.execute("この場面すごい", llm_client: llm_client, character: character)
      expect(result[:response]).to be_present
    end
  end
end
