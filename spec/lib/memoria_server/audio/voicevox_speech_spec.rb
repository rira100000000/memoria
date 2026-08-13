require "rails_helper"

RSpec.describe MemoriaServer::Audio::VoicevoxSpeech do
  let(:adapter) { described_class.new(base_url: "http://localhost:50021", default_speaker: "1") }

  describe "#synthesize" do
    let(:audio_query_response) {
      {
        accent_phrases: [],
        speedScale: 1.0,
        pitchScale: 0.0,
        intonationScale: 1.0,
        volumeScale: 1.0,
        prePhonemeLength: 0.1,
        postPhonemeLength: 0.1,
        outputSamplingRate: 24000,
        outputStereo: false,
        kana: ""
      }.to_json
    }

    it "calls audio_query then synthesis with the resolved speaker" do
      stub_request(:post, %r{http://localhost:50021/audio_query})
        .with(query: hash_including("speaker" => "3", "text" => "こんにちは"))
        .to_return(status: 200, body: audio_query_response, headers: { "Content-Type" => "application/json" })

      stub_request(:post, %r{http://localhost:50021/synthesis})
        .with(query: hash_including("speaker" => "3"))
        .to_return(status: 200, body: "WAVDATA", headers: { "Content-Type" => "audio/wav" })

      result = adapter.synthesize(input: "こんにちは", voice: "3", response_format: "wav")
      expect(result[:audio]).to eq("WAVDATA")
      expect(result[:content_type]).to eq("audio/wav")
    end

    it "falls back to default_speaker when voice is non-numeric (e.g. OpenAI 'alloy')" do
      stub_request(:post, %r{http://localhost:50021/audio_query})
        .with(query: hash_including("speaker" => "1"))
        .to_return(status: 200, body: audio_query_response)
      stub_request(:post, %r{http://localhost:50021/synthesis})
        .with(query: hash_including("speaker" => "1"))
        .to_return(status: 200, body: "WAV2")

      result = adapter.synthesize(input: "x", voice: "alloy")
      expect(result[:audio]).to eq("WAV2")
    end

    it "applies speed by overriding speedScale in the query" do
      captured_body = nil
      stub_request(:post, %r{http://localhost:50021/audio_query})
        .to_return(status: 200, body: audio_query_response)
      stub_request(:post, %r{http://localhost:50021/synthesis})
        .with { |req| captured_body = req.body; true }
        .to_return(status: 200, body: "WAV")

      adapter.synthesize(input: "x", speed: 1.5)
      expect(JSON.parse(captured_body)["speedScale"]).to eq(1.5)
    end

    it "raises on audio_query failure" do
      stub_request(:post, %r{http://localhost:50021/audio_query})
        .to_return(status: 422, body: "{\"detail\":\"bad\"}")
      expect {
        adapter.synthesize(input: "x")
      }.to raise_error(MemoriaServer::Error, /audio_query failed/)
    end

    it "raises on synthesis failure" do
      stub_request(:post, %r{http://localhost:50021/audio_query})
        .to_return(status: 200, body: audio_query_response)
      stub_request(:post, %r{http://localhost:50021/synthesis})
        .to_return(status: 500, body: "internal")
      expect {
        adapter.synthesize(input: "x")
      }.to raise_error(MemoriaServer::Error, /synthesis failed/)
    end
  end
end
