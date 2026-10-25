require "rails_helper"

RSpec.describe MessageDispatcher do
  let(:character) { create(:character) }

  describe ".dispatch" do
    it "does nothing for blank message" do
      expect { described_class.dispatch(character, "") }.not_to raise_error
    end

    it "does nothing when no channel bindings" do
      expect { described_class.dispatch(character, "test") }.not_to raise_error
    end
  end

  describe ".dispatch with channels for kinds of messages" do
    before do
      create(:channel_binding, character: character, channel_id: "1", purposes: ["default"])
      create(:channel_binding, character: character, channel_id: "2", purposes: ["dev"])
      allow(described_class).to receive(:send_to_discord)
    end

    it "sends only to the channel for the kind" do
      described_class.dispatch(character, "反映したよ", to: "dev")

      expect(described_class).to have_received(:send_to_discord).once.with("2", "反映したよ")
    end

    it "sends to the default channel without a kind" do
      described_class.dispatch(character, "おはよう")

      expect(described_class).to have_received(:send_to_discord).once.with("1", "おはよう")
    end
  end
end
