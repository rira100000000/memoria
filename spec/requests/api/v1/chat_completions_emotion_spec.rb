require "rails_helper"

RSpec.describe "Api::V1 chat_completions with emotion capability", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, name: "EmotionChar") }
  let(:device) { create(:device, slug: "emo-device") }
  let(:plain_key) { "msdk_emo_#{SecureRandom.hex(8)}" }
  let(:headers) { { "Authorization" => "Bearer #{plain_key}", "Content-Type" => "application/json" } }
  let(:fake_redis) { instance_double(::Redis, publish: 1) }

  before do
    DeviceKey.create!(device: device, key_hash: DeviceKey.hash_key(plain_key), label: "test")
    allow(MemoriaServer::RedisClient).to receive(:publisher).and_return(fake_redis)
    # EmotionAware アダプタをこのテスト中だけ active に
    @prev_adapter = MemoriaServer.adapter
    emotion_aware = MemoriaServer::Adapters::EmotionAwareMemoriaCore.new
    MemoriaServer.adapter = emotion_aware

    # ChatSession.find_or_create を mock
    @captured_extra_instruction = nil
    allow(::ChatSession).to receive(:find_or_create) do |_char, _user, **kwargs|
      @captured_extra_instruction = kwargs[:extra_system_instruction]
      session = instance_double(::ChatSession)
      allow(session).to receive(:send_message_stream) do |_input, &block|
        block.call(delta: %(<x_memoria>{"emotion":"happy"}</x_memoria>こん))
        block.call(delta: "にちは")
        block.call(done: true, usage: { input_tokens: 10, output_tokens: 3 })
      end
      session
    end
  end

  after do
    MemoriaServer.adapter = @prev_adapter if @prev_adapter
  end

  it "returns aggregated x_memoria in non-streaming response" do
    post "/api/v1/chat/completions", as: :json, headers: headers, params: {
      model: "memoria/#{character.vault_dir_name}",
      messages: [{ role: "user", content: "hi" }],
      x_memoria: { wants: ["emotion"] },
    }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    msg = body["choices"][0]["message"]
    expect(msg["content"]).to eq("こんにちは")
    expect(msg["x_memoria"]).to eq({ "emotion" => "happy" })
  end

  it "injects extra_system_instruction with x_memoria sentinel format" do
    post "/api/v1/chat/completions", as: :json, headers: headers, params: {
      model: "memoria/#{character.vault_dir_name}",
      messages: [{ role: "user", content: "hi" }],
      x_memoria: { wants: ["emotion"] },
    }
    expect(@captured_extra_instruction).to include("<x_memoria>")
    expect(@captured_extra_instruction).to match(/emotion/i)
  end

  it "does not inject instructions when wants is absent" do
    post "/api/v1/chat/completions", as: :json, headers: headers, params: {
      model: "memoria/#{character.vault_dir_name}",
      messages: [{ role: "user", content: "hi" }],
    }
    expect(@captured_extra_instruction).to be_nil
  end
end
