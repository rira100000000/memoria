require "rails_helper"

RSpec.describe Companion::AdoptPetTool do
  let(:character) { create(:character) }

  describe ".execute" do
    it "adopts a pet successfully" do
      result = described_class.execute(character: character, name: "モコ", appearance: "ふわふわの白い子犬")

      expect(result[:success]).to be true
      expect(character.reload.has_pet?).to be true
      expect(character.pet_name).to eq("モコ")
      expect(character.pet_appearance).to eq("ふわふわの白い子犬")
      expect(character.pet_traits).to include("肉球")
    end

    it "rejects if already has pet" do
      character.adopt_pet!(name: "先住", appearance: "まんまるの黒猫")
      result = described_class.execute(character: character, name: "新入り", appearance: "小さな青い鳥")

      expect(result[:error]).to include("先住")
    end

    it "rejects invalid appearance" do
      result = described_class.execute(character: character, name: "テスト", appearance: "巨大なドラゴン")
      expect(result[:error]).to be_present
    end
  end
end
