require "rails_helper"

RSpec.describe MemoriaCore::Core do
  let(:vault_path) { @vault_path }
  let(:core) { described_class.new(vault_path) }

  before { @vault_path = Dir.mktmpdir("memoria_test") }
  after { FileUtils.rm_rf(@vault_path) }

  describe "#tpn_count" do
    it "returns 0 for empty vault" do
      expect(core.tpn_count).to eq(0)
    end

    it "counts TPN files" do
      core # trigger ensure_structure!
      tpn_dir = File.join(vault_path, "TagProfilingNote")
      File.write(File.join(tpn_dir, "TPN-test.md"), "---\ntag_name: test\n---\nBody")
      File.write(File.join(tpn_dir, "TPN-other.md"), "---\ntag_name: other\n---\nBody")

      expect(core.tpn_count).to eq(2)
    end
  end

  describe "#sn_count" do
    it "returns 0 for empty vault" do
      expect(core.sn_count).to eq(0)
    end
  end

  describe "#last_user_conversation_age" do
    it "returns '不明' when no logs exist" do
      expect(core.last_user_conversation_age).to eq("不明")
    end
  end

  describe "#last_user_conversation_topic" do
    it "returns '不明' when no SNs exist" do
      expect(core.last_user_conversation_topic).to eq("不明")
    end

    it "returns title from latest SN" do
      core # trigger ensure_structure!
      sn_dir = File.join(vault_path, "SummaryNote")
      content = "---\ntitle: テスト会話\ndate: 2026-04-05 10:00\n---\nBody"
      File.write(File.join(sn_dir, "SN-202604051000-test.md"), content)

      expect(core.last_user_conversation_topic).to eq("テスト会話")
    end
  end

  describe "store accessors" do
    it "provides access to individual stores" do
      expect(core.vault).to be_a(MemoriaCore::VaultManager)
      expect(core.tpn_store).to be_a(MemoriaCore::TpnStore)
      expect(core.sn_store).to be_a(MemoriaCore::SnStore)
      expect(core.fl_store).to be_a(MemoriaCore::FlStore)
    end
  end
end
