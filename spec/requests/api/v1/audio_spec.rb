require "rails_helper"

RSpec.describe "Api::V1 audio endpoints", type: :request do
  let(:device) { create(:device, slug: "audio-dev") }
  let(:plain_key) { "msdk_audio_#{SecureRandom.hex(8)}" }
  let(:headers) { { "Authorization" => "Bearer #{plain_key}" } }

  before do
    DeviceKey.create!(device: device, key_hash: DeviceKey.hash_key(plain_key), label: "test")
  end

  describe "POST /api/v1/audio/transcriptions" do
    let(:fake_transcription) {
      Class.new(MemoriaServer::Audio::TranscriptionAdapter) do
        attr_reader :received
        def transcribe(audio_io:, filename:, model: nil, language: nil, prompt: nil, temperature: nil, response_format: nil)
          @received = { filename: filename, model: model, language: language }
          { text: "hello world", raw: { "text" => "hello world", "language" => "en" }, response_format: "json" }
        end
      end.new
    }

    before { MemoriaServer::Audio.transcription_adapter = fake_transcription }
    after { MemoriaServer::Audio.instance_variable_set(:@transcription_adapter, nil) }

    it "rejects without auth" do
      post "/api/v1/audio/transcriptions"
      expect(response).to have_http_status(:unauthorized)
    end

    it "transcribes uploaded audio file via the adapter" do
      file = Rack::Test::UploadedFile.new(StringIO.new("\0\0FAKEWAV"), "audio/wav", true, original_filename: "voice.wav")
      post "/api/v1/audio/transcriptions",
           headers: headers,
           params: { file: file, model: "whisper-1", language: "ja" }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["text"]).to eq("hello world")
      expect(json["language"]).to eq("en")
      expect(fake_transcription.received[:filename]).to eq("voice.wav")
      expect(fake_transcription.received[:language]).to eq("ja")
    end

    it "returns plain text when response_format=text" do
      file = Rack::Test::UploadedFile.new(StringIO.new("x"), "audio/wav", true, original_filename: "v.wav")
      post "/api/v1/audio/transcriptions",
           headers: headers,
           params: { file: file, response_format: "text" }
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/plain")
      expect(response.body).to eq("hello world")
    end

    it "rejects requests without file" do
      post "/api/v1/audio/transcriptions", headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/v1/audio/speech" do
    let(:fake_speech) {
      Class.new(MemoriaServer::Audio::SpeechAdapter) do
        attr_reader :received
        def synthesize(input:, voice: nil, model: nil, response_format: "mp3", speed: nil)
          @received = { input: input, voice: voice, response_format: response_format }
          { audio: "BINARYAUDIO", content_type: "audio/mpeg" }
        end
      end.new
    }

    before { MemoriaServer::Audio.speech_adapter = fake_speech }
    after { MemoriaServer::Audio.instance_variable_set(:@speech_adapter, nil) }

    it "rejects without auth" do
      post "/api/v1/audio/speech"
      expect(response).to have_http_status(:unauthorized)
    end

    it "synthesizes via adapter and returns binary audio" do
      post "/api/v1/audio/speech",
           headers: headers.merge("Content-Type" => "application/json"),
           params: { input: "こんにちは", voice: "alloy" }.to_json
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("audio/mpeg")
      expect(response.body).to eq("BINARYAUDIO")
      expect(fake_speech.received[:input]).to eq("こんにちは")
      expect(fake_speech.received[:voice]).to eq("alloy")
    end

    it "rejects empty input" do
      post "/api/v1/audio/speech",
           headers: headers.merge("Content-Type" => "application/json"),
           params: { input: "" }.to_json
      expect(response).to have_http_status(:bad_request)
    end
  end
end
