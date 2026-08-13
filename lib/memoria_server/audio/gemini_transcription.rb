require "gemini"

module MemoriaServer
  module Audio
    # Gemini で音声→テキスト変換する transcription adapter。
    # OpenAI Whisper の代替。GEMINI_API_KEY を流用する。
    #
    # Gemini は inline_data として audio (wav/mp3/etc.) を受け取り、generateContent で
    # 文字起こしテキストを返す（明示的な ASR API は無いが multimodal 入力で代替できる）。
    #
    # 環境変数:
    #   - GEMINI_API_KEY: 必須（既存と共有）
    #   - GEMINI_TRANSCRIBE_MODEL: デフォルト "gemini-2.5-flash"
    class GeminiTranscription < TranscriptionAdapter
      DEFAULT_MODEL = "gemini-2.5-flash".freeze
      DEFAULT_PROMPT = "この音声を文字起こししてください。テキスト本文のみ返答し、説明や前置きは不要です。".freeze

      def initialize(api_key: ENV["GEMINI_API_KEY"], default_model: ENV["GEMINI_TRANSCRIBE_MODEL"])
        raise MemoriaServer::Error, "GEMINI_API_KEY is not set" if api_key.to_s.empty?
        @client = Gemini::Client.new(api_key)
        @default_model = default_model.presence || DEFAULT_MODEL
      end

      def transcribe(audio_io:, filename:, model: nil, language: nil, prompt: nil, temperature: nil, response_format: nil)
        # ruby-gemini-api の Audio#transcribe は file.respond_to?(:path) で MIME を判定する。
        # ActionDispatch の UploadedFile.tempfile は path を持つので OK。
        # 念のため filename ヒントを使えるよう singleton method を生やしておく。
        unless audio_io.respond_to?(:path)
          ext = File.extname(filename.to_s)
          (class << audio_io; self; end).define_method(:path) { "transcribe#{ext}" }
        end

        response = @client.audio.transcribe(parameters: {
          file: audio_io,
          model: model.presence || @default_model,
          language: language,
          content_text: prompt.presence || DEFAULT_PROMPT,
        })

        text = response.text.to_s.strip
        { text: text, raw: { "text" => text }, response_format: "json" }
      rescue => e
        raise MemoriaServer::Error, "Gemini transcribe failed: #{e.class}: #{e.message}"
      end
    end
  end
end
