require "rails_helper"

RSpec.describe User, type: :model do
  describe "validations" do
    it "requires email" do
      user = build(:user, email: nil)
      expect(user).not_to be_valid
    end

    it "requires unique email" do
      create(:user, email: "dup@example.com")
      user = build(:user, email: "dup@example.com")
      expect(user).not_to be_valid
    end
  end

  describe "associations" do
    it "has many characters" do
      user = create(:user)
      create(:character, user: user)
      expect(user.characters.count).to eq(1)
    end

    it "has many chat_results" do
      expect(User.reflect_on_association(:chat_results).macro).to eq(:has_many)
    end

    it "has many api_usage_logs" do
      expect(User.reflect_on_association(:api_usage_logs).macro).to eq(:has_many)
    end
  end

  describe "api_token" do
    it "generates api_token on create" do
      user = create(:user)
      expect(user.api_token).to be_present
    end
  end

  describe "#vault_path" do
    it "returns path based on user id" do
      user = create(:user)
      expect(user.vault_path).to include(user.id.to_s)
    end
  end
end
