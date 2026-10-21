require "rails_helper"

RSpec.describe "Api::V1 chat_completions with message breaks", type: :request do
  let(:character) { create(:character) }
  let(:device) { create(:device, slug: "break-device") }
  let(:plain_key) { "msdk_break_#{SecureRandom.hex(8)}" }
  let(:headers) { { "Authorization" => "Bearer #{plain_key}", "Content-Type" => "application/json" } }
  let(:adapter_class) do
    Class.new(MemoriaServer::Adapter) do
      def respond(_input, context:)
        [{ delta: "調べてみるね" }, { message_break: true }, { delta: "分かったよ" }, { done: true, metadata: {} }].each
      end
    end
  end

  before do
    DeviceKey.create!(device: device, key_hash: DeviceKey.hash_key(plain_key), label: "test")
    allow(MemoriaServer::RedisClient).to receive(:publisher).and_return(instance_double(::Redis, publish: 1))
    @prev_adapter = MemoriaServer.adapter
    MemoriaServer.adapter = adapter_class.new
  end

  after { MemoriaServer.adapter = @prev_adapter }

  it "joins the messages with a blank line in one reply" do
    post "/api/v1/chat/completions", as: :json, headers: headers, params: {
      model: "memoria/#{character.vault_dir_name}",
      messages: [{ role: "user", content: "調べて" }],
    }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["choices"][0]["message"]["content"]).to eq("調べてみるね\n\n分かったよ")
  end
end
