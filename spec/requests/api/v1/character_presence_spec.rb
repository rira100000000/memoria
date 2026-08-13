require "rails_helper"

RSpec.describe "Api::V1::CharacterPresence", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:device_a) { create(:device, slug: "pres-a") }
  let(:device_b) { create(:device, slug: "pres-b") }
  let(:plain_a) { "msdk_pres_a_#{SecureRandom.hex(8)}" }
  let(:plain_b) { "msdk_pres_b_#{SecureRandom.hex(8)}" }
  let(:admin_plain) { "msak_pres_#{SecureRandom.hex(8)}" }
  let(:fake_redis) { instance_double(::Redis, publish: 1) }

  before do
    DeviceKey.create!(device: device_a, key_hash: DeviceKey.hash_key(plain_a), label: "test")
    DeviceKey.create!(device: device_b, key_hash: DeviceKey.hash_key(plain_b), label: "test")
    AdminKey.create!(key_hash: AdminKey.hash_key(admin_plain), label: "test")
    allow(MemoriaServer::RedisClient).to receive(:publisher).and_return(fake_redis)
  end

  describe "GET /api/v1/characters/:ref/presence" do
    it "returns null active_device when no presence" do
      get "/api/v1/characters/#{character.vault_dir_name}/presence",
        headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["active_device"]).to be_nil
    end

    it "returns the active device" do
      Presence.find_or_create_by!(character: character).update!(active_device: device_a)
      get "/api/v1/characters/#{character.vault_dir_name}/presence",
        headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(JSON.parse(response.body)["active_device"]["slug"]).to eq("pres-a")
    end

    it "supports lookup by numeric id" do
      get "/api/v1/characters/#{character.id}/presence",
        headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/characters/:ref/transfer" do
    it "device key can transfer to its own device" do
      post "/api/v1/characters/#{character.vault_dir_name}/transfer",
        params: { to_device: "pres-a" }, as: :json,
        headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["transferred"]).to be true
    end

    it "device key cannot transfer to other device" do
      post "/api/v1/characters/#{character.vault_dir_name}/transfer",
        params: { to_device: "pres-b" }, as: :json,
        headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "admin can transfer to any device" do
      post "/api/v1/characters/#{character.vault_dir_name}/transfer",
        params: { to_device: "pres-b", reason: "test" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end

    it "404 when target device unknown" do
      post "/api/v1/characters/#{character.vault_dir_name}/transfer",
        params: { to_device: "nope" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:not_found)
    end

    it "400 when to_device missing" do
      post "/api/v1/characters/#{character.vault_dir_name}/transfer",
        params: {}, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
