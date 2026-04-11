require "rails_helper"

RSpec.describe MemoriaCore::ContextRetriever do
  let(:vault) { instance_double(MemoriaCore::VaultManager) }
  let(:embedding_store) { instance_double(MemoriaCore::EmbeddingStore) }
  let(:retriever) { described_class.new(vault, embedding_store) }

  describe "#parse_date (via private method)" do
    # Test through format_date_short which calls parse_date internally
    # We test the fix for Time/Date objects from YAML parsing

    it "handles string dates" do
      result = retriever.send(:parse_date, "2025-01-15 10:30")
      expect(result).to be_a(Time)
      expect(result.year).to eq(2025)
      expect(result.month).to eq(1)
      expect(result.hour).to eq(10)
    end

    it "handles Time objects directly" do
      time = Time.new(2025, 3, 15, 14, 30)
      result = retriever.send(:parse_date, time)
      expect(result).to eq(time)
    end

    it "handles Date objects" do
      date = Date.new(2025, 3, 15)
      result = retriever.send(:parse_date, date)
      expect(result).to be_a(Time)
    end

    it "returns nil for nil input" do
      result = retriever.send(:parse_date, nil)
      expect(result).to be_nil
    end

    it "returns nil for unparseable string" do
      result = retriever.send(:parse_date, "not a date")
      expect(result).to be_nil
    end

    it "handles date strings with seconds" do
      result = retriever.send(:parse_date, "2025-01-15 10:30:45")
      expect(result.sec).to eq(45)
    end
  end

  describe "#importance_factor (private)" do
    it "is 1.0 for nil (no importance recorded)" do
      expect(retriever.send(:importance_factor, nil)).to eq(1.0)
    end

    it "is 1.0 for the neutral value 5" do
      expect(retriever.send(:importance_factor, 5)).to eq(1.0)
    end

    it "boosts above neutral" do
      expect(retriever.send(:importance_factor, 10)).to be_within(0.001).of(1.5)
      expect(retriever.send(:importance_factor, 8)).to be_within(0.001).of(1.3)
    end

    it "attenuates below neutral" do
      expect(retriever.send(:importance_factor, 1)).to be_within(0.001).of(0.6)
      expect(retriever.send(:importance_factor, 3)).to be_within(0.001).of(0.8)
    end

    it "clamps out-of-range numbers" do
      expect(retriever.send(:importance_factor, 15)).to be_within(0.001).of(1.5)
      expect(retriever.send(:importance_factor, -5)).to be_within(0.001).of(0.6)
    end

    it "ignores non-numeric input" do
      expect(retriever.send(:importance_factor, "high")).to eq(1.0)
    end
  end
end
