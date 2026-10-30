require "rails_helper"

# PUT・GET /api/v1/me/capabilities の契約:
# - 端末の鍵だけを通す（管理キーは通さない）。自分の端末の登録だけを変える
# - 標準にない ID は落として、落とした ID を返す。受け付けないキーは捨てて、名前を返す
# - 形が違うときは 422 で、登録は変わらない
RSpec.describe "/api/v1/me/capabilities" do
  let(:device) { create(:device) }
  let(:key) { DeviceKey.issue!(device: device, label: "t") }
  let(:headers) { { "Authorization" => "Bearer #{key}" } }
  let(:body) { { capabilities: { expression: { faces: %w[joy bogus], emotes: %w[goodbye-wave] }, secret: 1 } } }

  it "registers the vocabulary the device can show" do
    put "/api/v1/me/capabilities", params: body, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    json = response.parsed_body
    expect(json["capabilities"]["expression"]).to eq("faces" => %w[neutral joy], "emotes" => %w[goodbye-wave])
    expect(json["ignored"]).to eq(%w[secret])
    expect(json["dropped"]["expression"]).to eq("faces" => %w[bogus], "emotes" => [])
    expect(device.reload.capabilities["expression"]).to eq("faces" => %w[neutral joy], "emotes" => %w[goodbye-wave])
  end

  it "reads back what the device registered" do
    put "/api/v1/me/capabilities", params: body, headers: headers, as: :json

    get "/api/v1/me/capabilities", headers: headers

    expect(response.parsed_body["capabilities"]["expression"]["faces"]).to eq(%w[neutral joy])
  end

  it "answers 422 and keeps the registration when the shape is wrong" do
    put "/api/v1/me/capabilities", params: { capabilities: { expression: "joy" } }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(device.reload.capabilities).to eq({})
  end

  it "changes only the device of the key" do
    other = create(:device)

    put "/api/v1/me/capabilities", params: body, headers: headers, as: :json

    expect(other.reload.capabilities).to eq({})
  end

  it "refuses without a key, and with an admin key" do
    put "/api/v1/me/capabilities", params: body, as: :json
    expect(response).to have_http_status(:unauthorized)

    admin = AdminKey.issue!(label: "t")
    put "/api/v1/me/capabilities", params: body, headers: { "Authorization" => "Bearer #{admin}" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
