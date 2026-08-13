require "rails_helper"

RSpec.describe MemoriaServer::Push do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:device) { create(:device, slug: "push-test") }
  let(:fake_redis) { instance_double(::Redis, publish: 1) }

  before do
    allow(MemoriaServer::RedisClient).to receive(:publisher).and_return(fake_redis)
  end

  describe ".utter" do
    context "with active device" do
      before do
        allow(MemoriaServer::Push).to receive(:publish_to_device).and_call_original
        Presence.find_or_create_by!(character: character).update!(active_device: device)
      end

      it "publishes utter event to the device channel" do
        expect(fake_redis).to receive(:publish).with(
          "memoria:device:push-test:events",
          a_string_matching(/"event":"utter"/)
        )
        described_class.utter(character_id: character.id, text: "hi", emotion: "happy")
      end
    end

    context "without active device" do
      it "raises NoActiveDevice" do
        expect {
          described_class.utter(character_id: character.id, text: "hi")
        }.to raise_error(MemoriaServer::NoActiveDevice)
      end
    end
  end

  describe ".action" do
    before do
      Presence.find_or_create_by!(character: character).update!(active_device: device)
    end

    it "publishes action event" do
      expect(fake_redis).to receive(:publish).with(
        "memoria:device:push-test:events",
        a_string_matching(/"event":"action"/)
      )
      described_class.action(character_id: character.id, command: "dance", params: { sec: 5 })
    end
  end

  describe ".transfer" do
    let(:device_b) { create(:device, slug: "push-test-b") }

    it "delegates to PresenceManager" do
      expect(MemoriaServer::PresenceManager).to receive(:transfer!).with(
        hash_including(character: character, to_device: device_b)
      )
      described_class.transfer(character_id: character.id, to_device: "push-test-b")
    end

    it "raises when target device not found" do
      expect {
        described_class.transfer(character_id: character.id, to_device: "no-such-device")
      }.to raise_error(MemoriaServer::Error, /destination device not found/)
    end
  end

  describe ".channel_for" do
    it "returns the device-scoped channel name" do
      expect(described_class.channel_for(device)).to eq("memoria:device:push-test:events")
    end
  end
end
