require "rails_helper"
require "tempfile"

RSpec.describe MemoriaServer::Audio::GeminiTranscription do
  let(:fake_response) {
    instance_double(Gemini::Response, text: "こんにちは世界")
  }
  let(:fake_audio_api) {
    instance_double(Gemini::Audio).tap do |api|
      allow(api).to receive(:transcribe).and_return(fake_response)
    end
  }
  let(:fake_client) {
    instance_double(Gemini::Client, audio: fake_audio_api)
  }

  before do
    allow(Gemini::Client).to receive(:new).and_return(fake_client)
  end

  describe "#transcribe" do
    it "calls Gemini audio.transcribe and returns the text" do
      adapter = described_class.new(api_key: "AIza-fake")
      Tempfile.create(["voice", ".wav"]) do |f|
        f.write("\0\0FAKE")
        f.rewind
        result = adapter.transcribe(audio_io: f, filename: "voice.wav", language: "ja")
        expect(result[:text]).to eq("こんにちは世界")
        expect(result[:raw]).to eq({ "text" => "こんにちは世界" })
        expect(fake_audio_api).to have_received(:transcribe).with(
          parameters: hash_including(
            model: "gemini-2.5-flash",
            language: "ja",
          )
        )
      end
    end

    it "raises if GEMINI_API_KEY is missing" do
      expect {
        described_class.new(api_key: nil)
      }.to raise_error(MemoriaServer::Error, /GEMINI_API_KEY/)
    end

    it "wraps gemini errors in MemoriaServer::Error" do
      allow(fake_audio_api).to receive(:transcribe).and_raise(StandardError, "boom")
      adapter = described_class.new(api_key: "AIza-fake")
      Tempfile.create(["v", ".wav"]) do |f|
        expect {
          adapter.transcribe(audio_io: f, filename: "v.wav")
        }.to raise_error(MemoriaServer::Error, /boom/)
      end
    end

    it "passes a custom prompt as content_text when provided" do
      adapter = described_class.new(api_key: "AIza-fake")
      Tempfile.create(["v", ".wav"]) do |f|
        adapter.transcribe(audio_io: f, filename: "v.wav", prompt: "短く文字起こし")
      end
      expect(fake_audio_api).to have_received(:transcribe).with(
        parameters: hash_including(content_text: "短く文字起こし")
      )
    end
  end
end
