require "rails_helper"

RSpec.describe "Api::V1::Devices", type: :request do
  let(:device_a) { create(:device, slug: "dev-a") }
  let(:device_b) { create(:device, slug: "dev-b") }
  let(:plain_a) { "msdk_a_#{SecureRandom.hex(8)}" }
  let(:plain_b) { "msdk_b_#{SecureRandom.hex(8)}" }
  let(:admin_plain) { "msak_admin_#{SecureRandom.hex(8)}" }
  before do
    DeviceKey.create!(device: device_a, key_hash: DeviceKey.hash_key(plain_a), label: "test")
    DeviceKey.create!(device: device_b, key_hash: DeviceKey.hash_key(plain_b), label: "test")
    AdminKey.create!(key_hash: AdminKey.hash_key(admin_plain), label: "test")
  end

  describe "GET /api/v1/devices" do
    it "is admin-only" do
      get "/api/v1/devices", headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "lists all devices for admin" do
      get "/api/v1/devices", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
      slugs = JSON.parse(response.body)["devices"].map { |d| d["slug"] }
      expect(slugs).to include("dev-a", "dev-b")
    end
  end

  describe "GET /api/v1/devices/:slug" do
    it "allows device key to inspect own device" do
      get "/api/v1/devices/dev-a", headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:ok)
    end

    it "forbids device key from inspecting another device" do
      get "/api/v1/devices/dev-b", headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "allows admin to inspect any device" do
      get "/api/v1/devices/dev-b", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:ok)
    end

    it "404 for unknown slug" do
      get "/api/v1/devices/nope", headers: { "Authorization" => "Bearer #{admin_plain}" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/devices/:slug/heartbeat" do
    it "updates last_heartbeat_at for own device" do
      post "/api/v1/devices/dev-a/heartbeat", headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "forbids heartbeating another device" do
      post "/api/v1/devices/dev-b/heartbeat", headers: { "Authorization" => "Bearer #{plain_a}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the active character if any" do
      user = create(:user)
      char = create(:character, user: user, name: "HBChar")
      Presence.find_or_create_by!(character: char).update!(active_device: device_a)
      post "/api/v1/devices/dev-a/heartbeat", headers: { "Authorization" => "Bearer #{plain_a}" }
      body = JSON.parse(response.body)
      expect(body["active_character"]["name"]).to eq("HBChar")
    end
  end
end
