require "rails_helper"

RSpec.describe ChannelBinding, type: :model do
  describe "validations" do
    it "requires platform" do
      b = build(:channel_binding, platform: nil)
      expect(b).not_to be_valid
    end

    it "requires channel_id" do
      b = build(:channel_binding, channel_id: nil)
      expect(b).not_to be_valid
    end

    it "enforces unique channel_id per platform" do
      create(:channel_binding, platform: "discord", channel_id: "123")
      dup = build(:channel_binding, platform: "discord", channel_id: "123")
      expect(dup).not_to be_valid
    end
  end

  describe ".find_character_for_discord" do
    it "returns character for bound channel" do
      binding = create(:channel_binding, platform: "discord", channel_id: "999")
      expect(ChannelBinding.find_character_for_discord("999")).to eq(binding.character)
    end

    it "returns nil for unbound channel" do
      expect(ChannelBinding.find_character_for_discord("unknown")).to be_nil
    end
  end

  describe ".destinations" do
    let(:character) { create(:character) }
    let!(:news) { create(:channel_binding, character: character, purposes: ["default"]) }
    let!(:chat) { create(:channel_binding, character: character, purposes: ["chat"]) }
    let!(:dev) { create(:channel_binding, character: character, purposes: %w[dev system]) }

    def destinations(to) = described_class.destinations(character.channel_bindings, to)

    it "picks the channels for the kind" do
      expect(destinations("chat")).to eq([chat])
      expect(destinations("system")).to eq([dev])
    end

    it "uses the default channel without a kind, or for a kind no channel takes" do
      expect(destinations(nil)).to eq([news])
      expect(destinations("unknown")).to eq([news])
    end

    it "sends to every channel when none is the default" do
      news.update!(purposes: [])

      expect(destinations(nil)).to contain_exactly(news, chat, dev)
    end
  end
end
