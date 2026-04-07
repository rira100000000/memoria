require "rails_helper"

RSpec.describe Reading::ReadingCompanion do
  let(:llm_client) { instance_double(LlmClient) }

  before do
    allow(llm_client).to receive(:generate).and_return({ text: "ふふ、そこが気になったんだね。確かに印象的な場面だよね。" })
  end

  describe "#respond" do
    it "returns companion response" do
      companion = described_class.new(llm_client: llm_client)
      result = companion.respond(
        message: "メロスの激怒がすごい！",
        work_title: "走れメロス",
        work_author: "太宰治",
        character_name: "ハル"
      )

      expect(result).to be_present
      expect(llm_client).to have_received(:generate) do |prompt, **kwargs|
        expect(prompt).to include("メロスの激怒がすごい！")
        expect(prompt).to include("走れメロス")
        expect(kwargs[:tier]).to eq(:light)
      end
    end

    it "returns nil on error" do
      allow(llm_client).to receive(:generate).and_raise(StandardError.new("API error"))
      companion = described_class.new(llm_client: llm_client)

      result = companion.respond(
        message: "test",
        work_title: "test",
        work_author: "test",
        character_name: "ハル"
      )

      expect(result).to be_nil
    end
  end

  describe "#ice_break" do
    it "returns ice break text" do
      companion = described_class.new(llm_client: llm_client)
      result = companion.ice_break(
        work_title: "走れメロス",
        work_author: "太宰治",
        character_name: "ハル"
      )

      expect(result).to be_present
    end
  end

  describe ".find_character" do
    it "returns nil when no companion set" do
      reader = create(:character)
      expect(described_class.find_character(for_character: reader)).to be_nil
    end

    it "returns companion when set" do
      user = create(:user)
      companion = create(:character, user: user, name: "トート")
      reader = create(:character, user: user, reading_companion: companion)
      expect(described_class.find_character(for_character: reader)).to eq(companion)
    end
  end
end
