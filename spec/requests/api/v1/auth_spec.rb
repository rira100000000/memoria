require "rails_helper"

RSpec.describe "Api::V1 authentication", type: :request do
  let(:device) { create(:device, slug: "auth-test") }
  let(:device_plain) { "msdk_authplain_#{SecureRandom.hex(8)}" }
  let!(:device_key) do
    DeviceKey.create!(device: device, key_hash: DeviceKey.hash_key(device_plain), label: "auth-test")
  end
  let(:admin_plain) { "msak_authplain_#{SecureRandom.hex(8)}" }
  let!(:admin_key) do
    AdminKey.create!(key_hash: AdminKey.hash_key(admin_plain), label: "auth-test")
  end

  describe "GET /api/v1/ping" do
    it "returns 401 without bearer" do
      get "/api/v1/ping"
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]["type"]).to eq("unauthorized")
    end

    it "returns 401 with invalid bearer" do
      get "/api/v1/ping", headers: { "Authorization" => "Bearer junk" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 200 with admin key" do
      get "/api/v1/ping", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["authenticated_as"]).to eq("admin")
    end

    it "returns 200 with device key" do
      get "/api/v1/ping", headers: { "Authorization" => "Bearer #{device_plain}" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["authenticated_as"]).to eq("device")
      expect(JSON.parse(response.body)["device"]["slug"]).to eq("auth-test")
    end
  end

  describe "GET /api/v1/ping/admin" do
    it "returns 403 with device key" do
      get "/api/v1/ping/admin", headers: { "Authorization" => "Bearer #{device_plain}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 200 with admin key" do
      get "/api/v1/ping/admin", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "key revocation" do
    it "revoked device key cannot authenticate" do
      device_key.revoke!
      get "/api/v1/ping", headers: { "Authorization" => "Bearer #{device_plain}" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "revoked admin key cannot authenticate" do
      admin_key.revoke!
      get "/api/v1/ping", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
