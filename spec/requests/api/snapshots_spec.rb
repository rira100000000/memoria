require "rails_helper"

RSpec.describe "Api::Snapshots", type: :request do
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

  describe "GET /api/characters/:id/snapshots" do
    it "returns 401 without authentication" do
      get api_character_snapshots_path(character)
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns head sha and history" do
      get api_character_snapshots_path(character), headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["current_branch"]).to be_present
      expect(body["history"]).to be_an(Array)
    end
  end

  describe "POST /api/characters/:id/snapshots" do
    it "creates a manual snapshot entry" do
      post api_character_snapshots_path(character),
        headers: auth_headers(user),
        params: { label: "smoke test" },
        as: :json

      expect(response).to have_http_status(:created).or have_http_status(:ok)
      expect(response.parsed_body).to have_key("sha")
    end
  end
end
