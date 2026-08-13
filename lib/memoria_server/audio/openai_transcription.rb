require "faraday"
require "faraday/multipart"

module MemoriaServer
  module Audio
    # OpenAI 音声認識 API へ multipart で proxy する transcription adapter。
    # 環境変数:
    #   - OPENAI_API_KEY: 必須
    #   - OPENAI_TRANSCRIPTION_BASE_URL: デフォルト https://api.openai.com/v1
    #   - OPENAI_TRANSCRIPTION_MODEL: デフォルト "whisper-1"
    class OpenaiTranscription < TranscriptionAdapter
      DEFAULT_BASE = "https://api.openai.com/v1".freeze
      DEFAULT_MODEL = "whisper-1".freeze

      def initialize(api_key: ENV["OPENAI_API_KEY"], base_url: ENV["OPENAI_TRANSCRIPTION_BASE_URL"], default_model: ENV["OPENAI_TRANSCRIPTION_MODEL"])
        @api_key = api_key
        @base_url = (base_url.presence || DEFAULT_BASE).chomp("/")
        @default_model = default_model.presence || DEFAULT_MODEL
      end

      def transcribe(audio_io:, filename:, model: nil, language: nil, prompt: nil, temperature: nil, response_format: nil)
        raise MemoriaServer::Error, "OPENAI_API_KEY is not set" if @api_key.to_s.empty?

        payload = {
          file: Faraday::Multipart::FilePart.new(audio_io, content_type_for(filename), filename),
          model: model.presence || @default_model,
        }
        payload[:language] = language if language.present?
        payload[:prompt] = prompt if prompt.present?
        payload[:temperature] = temperature.to_f if temperature.present?
        # OpenAI が認識する形式のみ転送。それ以外は "json" にフォールバック。
        payload[:response_format] = response_format if %w[json text srt verbose_json vtt].include?(response_format.to_s)

        resp = client.post("/audio/transcriptions", payload)
        unless resp.success?
          raise MemoriaServer::Error, "OpenAI transcription failed: status=#{resp.status} body=#{resp.body}"
        end

        body = resp.body
        text = body.is_a?(Hash) ? (body["text"] || body[:text]).to_s : body.to_s
        { text: text, raw: body.is_a?(Hash) ? body : { "text" => text }, response_format: "json" }
      end

      private

      def client
        @client ||= Faraday.new(url: @base_url) do |f|
          f.request :multipart
          f.headers["Authorization"] = "Bearer #{@api_key}"
          f.response :json, content_type: /\bjson$/
          f.adapter Faraday.default_adapter
        end
      end

      def content_type_for(filename)
        case File.extname(filename.to_s).downcase
        when ".wav" then "audio/wav"
        when ".mp3" then "audio/mpeg"
        when ".m4a", ".mp4" then "audio/mp4"
        when ".flac" then "audio/flac"
        when ".ogg" then "audio/ogg"
        when ".webm" then "audio/webm"
        when ".opus" then "audio/opus"
        else "application/octet-stream"
        end
      end
    end
  end
end
