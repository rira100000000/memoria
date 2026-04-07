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
        hal_impression: "メロスの激怒がすごい！",
        chunk_text: "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。",
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
        hal_impression: "test",
        chunk_text: "test",
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
    it "returns nil when character does not exist" do
      expect(described_class.find_character).to be_nil
    end

    it "returns character when exists" do
      user = create(:user)
      create(:character, user: user, name: "トート")
      expect(described_class.find_character).to be_present
      expect(described_class.find_character.name).to eq("トート")
    end
  end
end
