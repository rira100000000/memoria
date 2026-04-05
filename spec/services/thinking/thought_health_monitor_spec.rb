require "rails_helper"

RSpec.describe Thinking::ThoughtHealthMonitor do
  let(:core) { instance_double(MemoriaCore::Core) }

  describe ".report" do
    it "returns default values for empty logs" do
      allow(core).to receive(:recent_autonomous_sns).and_return([])
      allow(core).to receive(:recent_sns).and_return([])

      report = described_class.report(core)

      expect(report[:topic_diversity]).to eq(1.0)
      expect(report[:external_input_ratio]).to eq(1.0)
      expect(report[:sentiment_trend]).to eq("neutral")
      expect(report[:max_continuation_chain]).to eq(0)
      expect(report[:sample_count]).to eq(0)
    end

    it "detects negative sentiment trend" do
      logs = [
        { frontmatter: { "mood" => "不安で暗い", "tags" => ["a"] }, body: "" },
        { frontmatter: { "mood" => "落ち込み", "tags" => ["b"] }, body: "" },
        { frontmatter: { "mood" => "辛い", "tags" => ["c"] }, body: "" },
      ]
      allow(core).to receive(:recent_autonomous_sns).and_return(logs)
      allow(core).to receive(:recent_sns).and_return(logs)

      report = described_class.report(core)
      expect(report[:sentiment_trend]).to eq("negative")
    end

    it "counts continuation chains" do
      logs = [
        { frontmatter: { "action_items" => ["続きをやる"], "tags" => [] }, body: "" },
        { frontmatter: { "action_items" => ["引き続き進める"], "tags" => [] }, body: "" },
        { frontmatter: { "action_items" => ["休憩する"], "tags" => [] }, body: "" },
      ]
      allow(core).to receive(:recent_autonomous_sns).and_return(logs)
      allow(core).to receive(:recent_sns).and_return(logs)

      report = described_class.report(core)
      expect(report[:max_continuation_chain]).to eq(2)
    end
  end
end
