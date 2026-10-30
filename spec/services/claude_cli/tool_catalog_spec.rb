require "rails_helper"

RSpec.describe ClaudeCli::ToolCatalog do
  let(:shared) { { name: "recall", description: "a" } }
  let(:talk) { { name: "talk", description: "b" } }
  let(:by_platform) { { nil => [ shared ], discord: [ shared, talk ] } }

  describe ".merge" do
    it "名前の重複を除いた和集合を、入力の順で返す" do
      expect(described_class.merge(by_platform)[:tools].map { |t| t[:name] }).to eq(%w[recall talk])
    end

    it "ツールごとに、それを持つ経路を返す" do
      expect(described_class.merge(by_platform)[:platforms]).to eq("recall" => [ nil, :discord ], "talk" => [ :discord ])
    end

    it "最初に現れた定義を使う" do
      first = { name: "x", description: "first" }
      second = { name: "x", description: "second" }

      expect(described_class.merge({ nil => [ first ], discord: [ second ] })[:tools]).to eq([ first ])
    end

    it "入力を書き換えない" do
      expect { described_class.merge(by_platform) }.not_to(change { Marshal.dump(by_platform) })
    end

    it "空なら空" do
      expect(described_class.merge({})).to eq(tools: [], platforms: {})
    end
  end

  describe ".available?" do
    let(:platforms) { described_class.merge(by_platform)[:platforms] }

    it "そのツールを持つ経路でだけ true" do
      expect(described_class.available?(platforms, "talk", :discord)).to be(true)
      expect(described_class.available?(platforms, "talk", nil)).to be(false)
      expect(described_class.available?(platforms, :recall, nil)).to be(true)
    end

    it "知らないツール名は false で、platforms を変えない" do
      expect(described_class.available?(platforms, "nothing", :discord)).to be(false)
      expect(platforms.keys).to eq(%w[recall talk])
    end
  end
end
