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

    it "exposes a non-empty prompt_segment" do
      expect(subject.prompt_segment).to be_a(String)
      expect(subject.prompt_segment).not_to be_empty
    end
  end

  describe MemoriaServer::Capabilities::MOTION do
    it "extracts known motion values" do
      expect(subject.parse_value({ "motion" => "happy_wiggle" })).to eq("happy_wiggle")
      expect(subject.parse_value({ "motion" => "idle" })).to eq("idle")
    end

    it "rejects unknown values" do
      expect(subject.parse_value({ "motion" => "moonwalk" })).to be_nil
    end

    it "ignores other capability keys" do
      expect(subject.parse_value({ "emotion" => "happy" })).to be_nil
    end

    it "is registered globally and resolvable by name" do
      expect(MemoriaServer::Capability.find(:motion)).to eq(subject)
    end

    it "exposes a non-empty prompt_segment" do
      expect(subject.prompt_segment).to be_a(String)
      expect(subject.prompt_segment).not_to be_empty
    end
  end
end
