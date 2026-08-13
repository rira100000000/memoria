require "rails_helper"

RSpec.describe "Api::Branches", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  around do |example|
    Dir.mktmpdir do |tmpdir|
      original = ENV["VAULT_ROOT"]
      ENV["VAULT_ROOT"] = tmpdir
      example.run
    ensure
      ENV["VAULT_ROOT"] = original
    end
  end

  describe "GET /api/characters/:id/branches" do
    it "returns 401 without authentication" do
      get api_character_branches_path(character)
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns current branch and branch list" do
      get api_character_branches_path(character), headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["current"]).to be_present
      expect(body["branches"]).to be_an(Array)
    end
  end

  describe "POST /api/characters/:id/branches" do
    it "creates a branch" do
      post api_character_branches_path(character),
        headers: auth_headers(user),
        params: { name: "experiment" },
        as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["branch"]).to eq("experiment")
    end
  end
end
