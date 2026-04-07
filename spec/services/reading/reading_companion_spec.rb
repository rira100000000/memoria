require "rails_helper"

RSpec.describe Reading::ReadingCompanion do
  let(:llm_client) { instance_double(LlmClient) }

  before do
    allow(llm_client).to receive(:generate).and_return({ text: "ふふ、そこが気になったんだね。確かに印象的な場面だよね。" })
  end

  describe ".respond" do
    it "returns companion response" do
      result = described_class.respond(
        hal_impression: "メロスの激怒がすごい！",
        chunk_text: "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。",
        work_title: "走れメロス",
        work_author: "太宰治",
        character_name: "ハル",
        llm_client: llm_client
      )

      expect(result).to be_present
      expect(llm_client).to have_received(:generate) do |prompt, **kwargs|
        expect(prompt).to include("メロスの激怒がすごい！")
        expect(prompt).to include("走れメロス")
        expect(prompt).to include("ハル")
        expect(kwargs[:tier]).to eq(:light)
        expect(kwargs[:system_instruction]).to include("読書伴走者")
      end
    end

    it "truncates chunk text to 400 chars" do
      long_chunk = "あ" * 1000

      described_class.respond(
        hal_impression: "長い",
        chunk_text: long_chunk,
        work_title: "テスト",
        work_author: "テスト",
        character_name: "ハル",
        llm_client: llm_client
      )

      expect(llm_client).to have_received(:generate) do |prompt, **_|
        # 原文部分は400字に切られる
        expect(prompt.length).to be < 1000
      end
    end

    it "returns nil on error" do
      allow(llm_client).to receive(:generate).and_raise(StandardError.new("API error"))

      result = described_class.respond(
        hal_impression: "test",
        chunk_text: "test",
        work_title: "test",
        work_author: "test",
        character_name: "ハル",
        llm_client: llm_client
      )

      expect(result).to be_nil
    end
  end
end
