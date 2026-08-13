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
end
