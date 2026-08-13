require "faraday"

module MemoriaServer
  module Audio
    # OpenAI TTS API へ proxy する speech adapter。
    # 環境変数:
    #   - OPENAI_API_KEY: 必須
    #   - OPENAI_SPEECH_BASE_URL: デフォルト https://api.openai.com/v1
    #   - OPENAI_SPEECH_MODEL: デフォルト "tts-1"
    #   - OPENAI_SPEECH_VOICE: デフォルト "alloy"
    class OpenaiSpeech < SpeechAdapter
      DEFAULT_BASE = "https://api.openai.com/v1".freeze
      DEFAULT_MODEL = "tts-1".freeze
      DEFAULT_VOICE = "alloy".freeze

      CONTENT_TYPES = {
        "mp3" => "audio/mpeg",
        "opus" => "audio/opus",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "pcm" => "audio/pcm",
      }.freeze

      def initialize(api_key: ENV["OPENAI_API_KEY"], base_url: ENV["OPENAI_SPEECH_BASE_URL"], default_model: ENV["OPENAI_SPEECH_MODEL"], default_voice: ENV["OPENAI_SPEECH_VOICE"])
        @api_key = api_key
        @base_url = (base_url.presence || DEFAULT_BASE).chomp("/")
        @default_model = default_model.presence || DEFAULT_MODEL
        @default_voice = default_voice.presence || DEFAULT_VOICE
      end

      def synthesize(input:, voice: nil, model: nil, response_format: "mp3", speed: nil)
        raise MemoriaServer::Error, "OPENAI_API_KEY is not set" if @api_key.to_s.empty?

        fmt = CONTENT_TYPES.key?(response_format.to_s) ? response_format.to_s : "mp3"

        body = {
          model: model.presence || @default_model,
          voice: voice.presence || @default_voice,
          input: input,
          response_format: fmt,
        }
        body[:speed] = speed.to_f if speed.present?

        resp = client.post("/audio/speech") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = body.to_json
        end

        unless resp.success?
          raise MemoriaServer::Error, "OpenAI speech failed: status=#{resp.status} body=#{resp.body[0, 200]}"
        end

        { audio: resp.body, content_type: CONTENT_TYPES[fmt] }
      end

      private

      def client
        @client ||= Faraday.new(url: @base_url) do |f|
          f.headers["Authorization"] = "Bearer #{@api_key}"
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
