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
end
