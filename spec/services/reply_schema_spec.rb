require "rails_helper"

RSpec.describe ReplySchema do
  let(:base) do
    { type: "object", properties: { reply: { type: "string" } }, required: %w[reply] }.freeze
  end
  let(:face) do
    MemoriaServer::Capability.new(name: :face, value_format: "x", value_extractor: ->(o) { o }, prompt_segment: "顔を付けて",
                                  reply_schema: { face: { type: "string" } })
  end
  let(:pose) do
    MemoriaServer::Capability.new(name: :pose, value_format: "x", value_extractor: ->(o) { o }, prompt_segment: "姿勢を付けて",
                                  reply_schema: { pose: { type: "string" } })
  end

  describe ".for_turn" do
    it "capability がなければ base をそのまま返す" do
      expect(described_class.for_turn(base: base, capabilities: [])).to equal(base)
    end

    it "capability の項目を、properties と required に足す" do
      schema = described_class.for_turn(base: base, capabilities: [ face ])

      expect(schema[:properties].keys).to eq(%i[reply face])
      expect(schema[:required]).to eq(%w[reply face])
    end

    it "base を書き換えない" do
      described_class.for_turn(base: base, capabilities: [ face ])

      expect(base[:properties].keys).to eq(%i[reply])
      expect(base[:required]).to eq(%w[reply])
    end
  end

  describe ".for_process" do
    it "capability の項目を properties に足し、required は変えない（あってもなくてもよい）" do
      schema = described_class.for_process(base: base, capabilities: [ face, pose ])

      expect(schema[:properties].keys).to eq(%i[reply face pose])
      expect(schema[:required]).to eq(%w[reply])
    end

    it "capability がなければ base をそのまま返す" do
      expect(described_class.for_process(base: base, capabilities: [])).to equal(base)
    end

    it "同じ入力には同じ出力を返す" do
      expect(described_class.for_process(base: base, capabilities: [ face ])).to eq(described_class.for_process(base: base, capabilities: [ face ]))
    end
  end

  describe ".brief" do
    it "欲しい capability の指示文を並べ、欲しくないものは付けないと伝える" do
      text = described_class.brief(wanted: [ face ], all: [ face, pose ])

      expect(text).to include("顔を付けて")
      expect(text).to include("pose の項目は付けない")
      expect(text).not_to include("姿勢を付けて")
    end

    it "すべて欲しいときは、付けない旨を書かない" do
      expect(described_class.brief(wanted: [ face, pose ], all: [ face, pose ])).not_to include("付けない")
    end

    it "どれも欲しくないとき、付けないと伝えるだけにする" do
      expect(described_class.brief(wanted: [], all: [ face ])).to eq("今回の返答には、face の項目は付けない。")
    end

    it "capability がなければ nil" do
      expect(described_class.brief(wanted: [], all: [])).to be_nil
    end
  end
end
