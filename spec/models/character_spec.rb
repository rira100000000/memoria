require "rails_helper"

RSpec.describe Character, type: :model do
  describe "validations" do
    it "requires name" do
      char = build(:character, name: nil)
      expect(char).not_to be_valid
    end
  end

  describe "associations" do
    it "belongs to user" do
      expect(Character.reflect_on_association(:user).macro).to eq(:belongs_to)
    end
  end

  describe "#vault_dir_name" do
    it "sets vault_dir_name on create for ascii names" do
      char = create(:character, name: "TestChar")
      expect(char.vault_dir_name).to eq("testchar")
    end

    it "does not reuse another character's vault_dir_name of the same user" do
      first = create(:character, name: "TestChar")
      second = create(:character, name: "TestChar", user: first.user)

      expect(second.vault_dir_name).to match(/\Atestchar_[a-f0-9]{8}\z/)
    end

    it "rejects an explicitly given vault_dir_name that the user already uses" do
      first = create(:character, name: "A", vault_dir_name: "shared")
      second = build(:character, name: "B", vault_dir_name: "shared", user: first.user)

      expect(second).not_to be_valid
      expect(build(:character, name: "C", vault_dir_name: "shared")).to be_valid # 別のユーザーなら使える
    end

    it "generates fallback for non-ascii names" do
      char = create(:character, name: "テスト太郎")
      expect(char.vault_dir_name).to match(/\Achar_[a-f0-9]{8}\z/)
    end
  end

  describe "#vault_path" do
    it "returns path including user vault and vault_dir_name" do
      char = create(:character)
      expect(char.vault_path).to include(char.user.id.to_s)
      expect(char.vault_path).to include(char.vault_dir_name)
    end
  end
end
