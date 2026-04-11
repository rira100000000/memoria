require "rails_helper"
require "fileutils"

RSpec.describe MemoriaCore::FtsIndex do
  let(:vault_root) { Rails.root.join("tmp/spec_fts_#{SecureRandom.hex(4)}") }
  let(:vault) { MemoriaCore::VaultManager.new(vault_root.to_s) }
  let(:index) { described_class.new(vault) }

  before do
    FileUtils.mkdir_p(vault_root)
    vault.ensure_structure!
    index.initialize!
  end

  after do
    FileUtils.rm_rf(vault_root)
  end

  describe "#upsert and #search" do
    it "indexes content and finds it by exact substring" do
      index.upsert("SummaryNote/SN-test.md", "SN", "ハルが青空文庫の羅生門を読んだ感想")

      results = index.search("羅生門")
      expect(results.size).to eq(1)
      expect(results.first[:file_path]).to eq("SummaryNote/SN-test.md")
      expect(results.first[:source_type]).to eq("SN")
    end

    it "finds entries via trigram with 3+ character Japanese substrings" do
      index.upsert("SummaryNote/SN-1.md", "SN", "天体観測についての会話")
      index.upsert("SummaryNote/SN-2.md", "SN", "今日は雨だった")

      # trigram tokenizer は 3 文字以上の連続マッチが必要
      results = index.search("天体観")
      expect(results.size).to eq(1)
      expect(results.first[:file_path]).to end_with("SN-1.md")
    end

    it "ranks more relevant content higher (score is descending)" do
      index.upsert("SummaryNote/SN-many.md", "SN", "羅生門 羅生門 羅生門 芥川")
      index.upsert("SummaryNote/SN-once.md", "SN", "ある日、羅生門の話を少しした")

      results = index.search("羅生門")
      expect(results.size).to eq(2)
      expect(results.first[:file_path]).to end_with("SN-many.md")
      expect(results.first[:score]).to be > results.last[:score]
    end

    it "filters by source_type" do
      index.upsert("SummaryNote/SN-x.md", "SN", "テスト")
      index.upsert("TagProfilingNote/TPN-x.md", "TPN", "テスト")

      sn_results = index.search("テスト", source_type: "SN")
      expect(sn_results.map { |r| r[:source_type] }.uniq).to eq(["SN"])

      tpn_results = index.search("テスト", source_type: "TPN")
      expect(tpn_results.map { |r| r[:source_type] }.uniq).to eq(["TPN"])
    end

    it "upsert replaces previous content for the same file_path" do
      index.upsert("SummaryNote/SN-replace.md", "SN", "古い内容")
      index.upsert("SummaryNote/SN-replace.md", "SN", "新しい内容")

      expect(index.search("古い内容")).to be_empty
      expect(index.search("新しい内容").size).to eq(1)
      expect(index.count).to eq(1)
    end

    it "remove deletes the entry" do
      index.upsert("SummaryNote/SN-tmp.md", "SN", "一時的な内容")
      index.remove("SummaryNote/SN-tmp.md")
      expect(index.search("一時的")).to be_empty
    end

    it "returns empty array for empty / nil queries" do
      expect(index.search("")).to eq([])
      expect(index.search(nil)).to eq([])
    end

    it "is resilient to FTS5 special characters in queries" do
      index.upsert("SummaryNote/SN-special.md", "SN", "ハル(ハル)の話 *important*")

      expect { index.search("ハル(ハル)") }.not_to raise_error
      expect { index.search("*important*") }.not_to raise_error
    end
  end

  describe "#rebuild_from_vault!" do
    it "indexes all SN and TPN files in the vault" do
      vault.write("SummaryNote/SN-a.md", "---\ntitle: A\n---\n# A\n本文 alpha")
      vault.write("SummaryNote/SN-b.md", "---\ntitle: B\n---\n# B\n本文 beta")
      vault.write("TagProfilingNote/TPN-x.md", "---\ntag_name: x\n---\n# X\nプロファイル gamma")

      count = index.rebuild_from_vault!
      expect(count).to eq(3)
      expect(index.search("alpha").size).to eq(1)
      expect(index.search("beta").size).to eq(1)
      expect(index.search("gamma").size).to eq(1)
    end

    it "is idempotent (clears before re-indexing)" do
      vault.write("SummaryNote/SN-a.md", "---\ntitle: A\n---\n# A\nzeta")

      index.rebuild_from_vault!
      index.rebuild_from_vault!

      expect(index.count).to eq(1)
    end
  end
end
