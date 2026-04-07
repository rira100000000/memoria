require "rails_helper"

RSpec.describe Reading::AozoraCatalog do
  let(:csv_content) do
    <<~CSV
      作品ID,作品名,姓,名,テキストファイルURL,底本名1,入力者,分類番号
      1,走れメロス,太宰,治,https://www.aozora.gr.jp/cards/000035/files/1567_ruby_4948.zip,太宰治全集,テスト太郎,NDC 913
      2,こころ,夏目,漱石,https://www.aozora.gr.jp/cards/000148/files/773_ruby_5968.zip,夏目漱石全集,テスト花子,NDC 913
      3,テキストなし,芥川,龍之介,,芥川全集,テスト次郎,NDC 913
    CSV
  end

  let(:test_csv_path) { Rails.root.join("tmp/test_aozora_catalog.csv") }

  before do
    described_class.reset!
    File.write(test_csv_path, csv_content)
    stub_const("Reading::AozoraCatalog::CSV_PATH", test_csv_path)
  end

  after do
    described_class.reset!
    FileUtils.rm_f(test_csv_path)
  end

  describe ".available_works" do
    it "returns only rows with テキストファイルURL" do
      works = described_class.available_works
      expect(works.length).to eq(2)
      expect(works.map { |w| w["作品名"] }).to contain_exactly("走れメロス", "こころ")
    end
  end

  describe ".random_pick" do
    it "returns a random work" do
      work = described_class.random_pick
      expect(work).to be_present
      expect(work["テキストファイルURL"]).to be_present
    end

    it "filters by genre (author name)" do
      work = described_class.random_pick(genre: "太宰")
      expect(work["作品名"]).to eq("走れメロス")
    end

    it "filters by genre (work title)" do
      work = described_class.random_pick(genre: "こころ")
      expect(work["作品名"]).to eq("こころ")
    end

    it "excludes specified work_ids" do
      work = described_class.random_pick(exclude_ids: ["1"])
      expect(work["作品名"]).to eq("こころ")
    end

    it "returns nil when no candidates" do
      work = described_class.random_pick(exclude_ids: ["1", "2"])
      expect(work).to be_nil
    end
  end

  describe ".search" do
    it "finds works by author name" do
      results = described_class.search("太宰")
      expect(results.length).to eq(1)
      expect(results.first[:title]).to eq("走れメロス")
      expect(results.first[:work_id]).to eq("1")
    end

    it "finds works by title" do
      results = described_class.search("こころ")
      expect(results.length).to eq(1)
      expect(results.first[:author]).to eq("夏目漱石")
    end

    it "supports multi-term search" do
      results = described_class.search("太宰 メロス")
      expect(results.length).to eq(1)
    end

    it "returns empty for no matches" do
      results = described_class.search("存在しない作品")
      expect(results).to be_empty
    end

    it "returns empty for blank query" do
      expect(described_class.search("")).to be_empty
      expect(described_class.search(nil)).to be_empty
    end

    it "excludes works without テキストファイルURL" do
      results = described_class.search("芥川")
      expect(results).to be_empty
    end
  end

  describe ".find_by_id" do
    it "finds a work by ID" do
      work = described_class.find_by_id("1")
      expect(work["作品名"]).to eq("走れメロス")
    end

    it "returns nil for unknown ID" do
      expect(described_class.find_by_id("999")).to be_nil
    end

    it "excludes works without テキストファイルURL" do
      expect(described_class.find_by_id("3")).to be_nil
    end
  end
end
