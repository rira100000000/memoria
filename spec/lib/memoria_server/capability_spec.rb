require "rails_helper"

RSpec.describe MemoriaServer::Capability do
  describe ".register / .find" do
    it "registers and finds by name (string or symbol)" do
      cap = described_class.new(
        name: :test_cap_xyz,
        value_format: "test",
        value_extractor: ->(obj) { obj["x"] },
      )
      described_class.register(cap)
      expect(described_class.find(:test_cap_xyz)).to eq(cap)
      expect(described_class.find("test_cap_xyz")).to eq(cap)
    end
  end

  describe ".resolve_many" do
    it "ignores unknown names" do
      caps = described_class.resolve_many(["emotion", "no_such_cap", :emotion])
      expect(caps.map(&:name)).to all(eq(:emotion))
      expect(caps.size).to eq(2)
    end

    it "returns empty array for nil/empty input" do
      expect(described_class.resolve_many(nil)).to eq([])
      expect(described_class.resolve_many([])).to eq([])
    end
  end

  describe MemoriaServer::Capabilities::EMOTION do
    it "extracts known emotion values" do
      expect(subject.parse_value({ "emotion" => "happy" })).to eq("happy")
      expect(subject.parse_value({ "emotion" => "sad" })).to eq("sad")
    end

    it "rejects unknown values" do
      expect(subject.parse_value({ "emotion" => "ecstatic" })).to be_nil
      expect(subject.parse_value({ "emotion" => "" })).to be_nil
    end

    it "ignores missing key" do
      expect(subject.parse_value({})).to be_nil
      expect(subject.parse_value({ "other" => "happy" })).to be_nil
    end

    it "accepts symbol keys too" do
      expect(subject.parse_value({ emotion: "angry" })).to eq("angry")
    end
  end
end
