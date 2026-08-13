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
end
