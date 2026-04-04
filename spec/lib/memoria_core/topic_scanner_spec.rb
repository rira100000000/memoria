require "rails_helper"

RSpec.describe MemoriaCore::TopicScanner do
  let(:vault) { instance_double(MemoriaCore::VaultManager) }
  let(:tpn_store) { instance_double(MemoriaCore::TpnStore) }
  let(:scanner) { described_class.new(vault) }

  before do
    allow(MemoriaCore::TpnStore).to receive(:new).and_return(tpn_store)
  end

  describe "#scan" do
    it "returns empty when no TPNs exist" do
      allow(tpn_store).to receive(:list).and_return([])
      expect(scanner.scan).to be_empty
    end

    it "identifies stale topics" do
      allow(tpn_store).to receive(:list).and_return(["TagProfilingNote/TPN-test.md"])

      stale_date = (Time.now - 30 * 86400).strftime("%Y-%m-%d %H:%M")
      tpn_content = <<~MD
        ---
        tag_name: test
        updated_date: "#{stale_date}"
        master_significance: "重要なトピック"
        ---

        Test body
      MD
      allow(vault).to receive(:read).and_return(tpn_content)

      results = scanner.scan
      expect(results).not_to be_empty
      expect(results.first[:tag]).to eq("test")
      expect(results.first[:reasons]).to include(a_string_matching(/日間更新なし/))
    end

    it "identifies topics with high significance keywords" do
      allow(tpn_store).to receive(:list).and_return(["TagProfilingNote/TPN-goal.md"])

      tpn_content = <<~MD
        ---
        tag_name: goal
        updated_date: "#{Time.now.strftime('%Y-%m-%d %H:%M')}"
        master_significance: "ユーザーの大切な目標"
        action_items:
          - "進捗確認する"
        ---

        Goal body
      MD
      allow(vault).to receive(:read).and_return(tpn_content)

      results = scanner.scan
      expect(results).not_to be_empty
      expect(results.first[:reasons]).to include("重要トピック")
    end

    it "filters out low-score topics" do
      allow(tpn_store).to receive(:list).and_return(["TagProfilingNote/TPN-boring.md"])

      tpn_content = <<~MD
        ---
        tag_name: boring
        updated_date: "#{Time.now.strftime('%Y-%m-%d %H:%M')}"
        master_significance: ""
        ---

        Nothing special
      MD
      allow(vault).to receive(:read).and_return(tpn_content)

      results = scanner.scan
      expect(results).to be_empty
    end
  end
end
