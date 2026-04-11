require "rails_helper"
require "fileutils"

RSpec.describe MemoriaCore::TagProfiler do
  let(:vault_root) { Rails.root.join("tmp/spec_vault_#{SecureRandom.hex(4)}") }
  let(:vault) { MemoriaCore::VaultManager.new(vault_root.to_s) }
  let(:llm_client) { instance_double("LlmClient") }
  let(:profiler) { described_class.new(vault, llm_client, llm_role_name: "ハル", system_prompt: "") }

  let(:llm_response_text) do
    <<~JSON
      ```json
      {
        "tag_name": "天体観測",
        "aliases": [],
        "key_themes": ["星", "夜空"],
        "user_sentiment_overall": "前向き",
        "user_sentiment_details": [],
        "master_significance": "テスト",
        "related_tags": [],
        "body_semantic": "夜空の天体を観察すること",
        "body_overview": "概要",
        "body_contexts": [],
        "body_user_opinions": [],
        "body_other_notes": "",
        "new_base_importance": 60
      }
      ```
    JSON
  end

  before do
    FileUtils.mkdir_p(vault_root)
    vault.ensure_structure!
    allow(llm_client).to receive(:generate).and_return({ text: llm_response_text })
  end

  after do
    FileUtils.rm_rf(vault_root)
  end

  def write_sn(filename, tags:, importance:)
    fm = {
      "title" => "テスト会話",
      "date" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      "type" => "conversation_summary",
      "tags" => tags,
      "importance" => importance,
    }
    body = "# テスト会話\n\n適当な本文。\n"
    path = File.join(MemoriaCore::VaultManager::SN_DIR, filename)
    vault.write(path, MemoriaCore::Frontmatter.build(fm, body))
    path
  end

  def tag_scores
    JSON.parse(vault.read(MemoriaCore::VaultManager::TAG_SCORES_FILE) || "{}")
  end

  def tpn_exists?(tag)
    !MemoriaCore::TpnStore.new(vault).read_raw(tag).nil?
  end

  describe "promotion gate" do
    it "skips TPN creation for a single low-importance mention" do
      sn_path = write_sn("SN-test1.md", tags: ["天体観測"], importance: 3)
      profiler.process_summary_note(sn_path)

      expect(tpn_exists?("天体観測")).to be false
      expect(llm_client).not_to have_received(:generate)

      score = tag_scores["天体観測"]
      expect(score["mention_frequency"]).to eq(1)
      expect(score["importance_sum"]).to eq(3)
      expect(score["promoted_at"]).to be_nil
    end

    it "creates TPN immediately for a single highly-important mention" do
      sn_path = write_sn("SN-test2.md", tags: ["告白"], importance: 10)
      profiler.process_summary_note(sn_path)

      expect(tpn_exists?("告白")).to be true
      expect(llm_client).to have_received(:generate).once

      score = tag_scores["告白"]
      expect(score["importance_sum"]).to eq(10)
      expect(score["promoted_at"]).to be_present
    end

    it "promotes a tag once accumulated importance crosses the threshold" do
      # 1 回目: importance 5 (合計 5、しきい値未満なので TPN なし)
      profiler.process_summary_note(write_sn("SN-a.md", tags: ["散歩"], importance: 5))
      expect(tpn_exists?("散歩")).to be false

      # 2 回目: importance 5 (合計 10、しきい値到達で promote)
      profiler.process_summary_note(write_sn("SN-b.md", tags: ["散歩"], importance: 5))
      expect(tpn_exists?("散歩")).to be true
      expect(llm_client).to have_received(:generate).once

      score = tag_scores["散歩"]
      expect(score["mention_frequency"]).to eq(2)
      expect(score["importance_sum"]).to eq(10)
      expect(score["promoted_at"]).to be_present
    end

    it "promotes a tag once mention frequency crosses the threshold (low-importance reps)" do
      # importance 1 を 3 回 → importance_sum=3 (しきい値未満) だが
      # mention_frequency=3 でしきい値到達
      profiler.process_summary_note(write_sn("SN-c1.md", tags: ["雑談"], importance: 1))
      profiler.process_summary_note(write_sn("SN-c2.md", tags: ["雑談"], importance: 1))
      expect(tpn_exists?("雑談")).to be false

      profiler.process_summary_note(write_sn("SN-c3.md", tags: ["雑談"], importance: 1))
      expect(tpn_exists?("雑談")).to be true
      expect(tag_scores["雑談"]["mention_frequency"]).to eq(3)
    end

    it "still updates an already-promoted tag (subsequent mentions hit the LLM each time)" do
      profiler.process_summary_note(write_sn("SN-d1.md", tags: ["重要話題"], importance: 10))
      profiler.process_summary_note(write_sn("SN-d2.md", tags: ["重要話題"], importance: 1))

      expect(llm_client).to have_received(:generate).twice
      score = tag_scores["重要話題"]
      expect(score["mention_frequency"]).to eq(2)
      expect(score["importance_sum"]).to eq(11)
    end

    it "treats SNs without importance frontmatter as neutral (5)" do
      sn_path = write_sn("SN-e.md", tags: ["未評価"], importance: nil)
      profiler.process_summary_note(sn_path)

      score = tag_scores["未評価"]
      expect(score["importance_sum"]).to eq(5)
      # 5 は単独ではしきい値未満
      expect(tpn_exists?("未評価")).to be false
    end
  end
end
