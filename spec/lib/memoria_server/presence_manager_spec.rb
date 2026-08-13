require "rails_helper"

RSpec.describe MemoriaServer::PresenceManager do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:device_a) { create(:device, slug: "pm-a") }
  let(:device_b) { create(:device, slug: "pm-b") }

  describe ".transfer!" do
    before do
      allow(MemoriaServer::Push).to receive(:publish_to_device)
    end

    it "creates a presence record on first transfer" do
      result = described_class.transfer!(character: character, to_device: device_a)
      expect(result[:transferred]).to be true
      expect(result[:from_device]).to be_nil
      expect(result[:to_device]).to eq(device_a)
      expect(Presence.find_by(character_id: character.id).active_device_id).to eq(device_a.id)
    end

    it "switches active device on subsequent transfer" do
      described_class.transfer!(character: character, to_device: device_a)
      result = described_class.transfer!(character: character, to_device: device_b)
      expect(result[:transferred]).to be true
      expect(result[:from_device]).to eq(device_a)
      expect(result[:to_device]).to eq(device_b)
    end

    it "returns transferred: false for same-device transfer (no-op)" do
      described_class.transfer!(character: character, to_device: device_a)
      result = described_class.transfer!(character: character, to_device: device_a)
      expect(result[:transferred]).to be false
    end

    it "records a Transfer log entry" do
      expect {
        described_class.transfer!(character: character, to_device: device_a, reason: "test")
      }.to change(Transfer, :count).by(1)
      expect(Transfer.last.reason).to eq("test")
      expect(Transfer.last.to_device).to eq(device_a)
    end

    it "does not record Transfer for no-op same-device transfer" do
      described_class.transfer!(character: character, to_device: device_a)
      expect {
        described_class.transfer!(character: character, to_device: device_a)
      }.not_to change(Transfer, :count)
    end

    it "publishes presence.arrived on first transfer" do
      expect(MemoriaServer::Push).to receive(:publish_to_device).with(device_a, "presence.arrived", anything)
      described_class.transfer!(character: character, to_device: device_a)
    end

    it "publishes departed and arrived on switch" do
      described_class.transfer!(character: character, to_device: device_a)
      expect(MemoriaServer::Push).to receive(:publish_to_device).with(device_a, "presence.departed", anything)
      expect(MemoriaServer::Push).to receive(:publish_to_device).with(device_b, "presence.arrived", anything)
      described_class.transfer!(character: character, to_device: device_b)
    end
  end

  describe ".release!" do
    before { allow(MemoriaServer::Push).to receive(:publish_to_device) }

    it "no-ops if no presence row" do
      expect { described_class.release!(character: character) }.not_to raise_error
    end

    it "no-ops if presence has no active_device" do
      Presence.create!(character: character)
      expect(MemoriaServer::Push).not_to receive(:publish_to_device)
      described_class.release!(character: character)
    end

    it "releases active device and publishes departed" do
      described_class.transfer!(character: character, to_device: device_a)
      expect(MemoriaServer::Push).to receive(:publish_to_device).with(device_a, "presence.departed", hash_including(reason: "test"))
      described_class.release!(character: character, reason: "test")
      expect(Presence.find_by(character_id: character.id).active_device_id).to be_nil
    end

    it "does not write a Transfer log entry" do
      described_class.transfer!(character: character, to_device: device_a)
      expect {
        described_class.release!(character: character)
      }.not_to change(Transfer, :count)
    end
  end

  describe ".active_device" do
    it "returns nil if no presence" do
      expect(described_class.active_device(character)).to be_nil
    end

    it "returns the active device after transfer" do
      allow(MemoriaServer::Push).to receive(:publish_to_device)
      described_class.transfer!(character: character, to_device: device_a)
      expect(described_class.active_device(character)).to eq(device_a)
    end
  end
end
