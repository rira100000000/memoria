require "rails_helper"

RSpec.describe "Api::V1::CharacterActions", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, name: "ActChar") }
  let(:device_active) { create(:device, slug: "act-active") }
  let(:device_idle) { create(:device, slug: "act-idle") }
  let(:plain_active) { "msdk_act_active_#{SecureRandom.hex(8)}" }
  let(:plain_idle) { "msdk_act_idle_#{SecureRandom.hex(8)}" }
  let(:admin_plain) { "msak_act_#{SecureRandom.hex(8)}" }
  let(:fake_redis) { instance_double(::Redis, publish: 1) }

  before do
    DeviceKey.create!(device: device_active, key_hash: DeviceKey.hash_key(plain_active), label: "test")
    DeviceKey.create!(device: device_idle, key_hash: DeviceKey.hash_key(plain_idle), label: "test")
    AdminKey.create!(key_hash: AdminKey.hash_key(admin_plain), label: "test")
    Presence.find_or_create_by!(character: character).update!(active_device: device_active)
    allow(MemoriaServer::RedisClient).to receive(:publisher).and_return(fake_redis)
  end

  describe "POST /api/v1/characters/:ref/utter" do
    it "is admin-only" do
      post "/api/v1/characters/#{character.vault_dir_name}/utter",
        params: { text: "x" }, as: :json,
        headers: { "Authorization" => "Bearer #{plain_active}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "publishes utter for admin" do
      expect(fake_redis).to receive(:publish).with(/act-active/, a_string_matching(/utter/))
      post "/api/v1/characters/#{character.vault_dir_name}/utter",
        params: { text: "hi", emotion: "happy" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end

    it "returns 409 when no active device" do
      Presence.find_by(character_id: character.id).update!(active_device: nil)
      post "/api/v1/characters/#{character.vault_dir_name}/utter",
        params: { text: "hi" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:conflict)
    end

    it "requires text" do
      post "/api/v1/characters/#{character.vault_dir_name}/utter",
        params: { text: "" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/v1/characters/:ref/action" do
    it "publishes action for admin" do
      expect(fake_redis).to receive(:publish).with(/act-active/, a_string_matching(/action/))
      post "/api/v1/characters/#{character.vault_dir_name}/action",
        params: { command: "wave", params: { hand: "right" } }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/characters/:ref/conversation/boundary" do
    it "active device key can signal boundary" do
      allow(MemoriaServer.adapter).to receive(:on_boundary).and_return(nil)
      post "/api/v1/characters/#{character.vault_dir_name}/conversation/boundary",
        params: { reason: "user" }, as: :json,
        headers: { "Authorization" => "Bearer #{plain_active}" }
      expect(response).to have_http_status(:ok)
    end

    it "idle device key cannot" do
      post "/api/v1/characters/#{character.vault_dir_name}/conversation/boundary",
        params: { reason: "user" }, as: :json,
        headers: { "Authorization" => "Bearer #{plain_idle}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "admin can" do
      allow(MemoriaServer.adapter).to receive(:on_boundary).and_return(nil)
      post "/api/v1/characters/#{character.vault_dir_name}/conversation/boundary",
        params: { reason: "schedule" }, as: :json,
        headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end
  end
end
