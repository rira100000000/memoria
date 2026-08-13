module MemoriaServer
  # 音声系（ASR/TTS）アダプタの解決。
  # MS_TRANSCRIPTION_ADAPTER / MS_SPEECH_ADAPTER で実装を切り替えられる。
  # 既定は OpenAI proxy で、将来的に AivisSpeech / faster-whisper / VOICEVOX 等に差し替え可能。
  module Audio
    TRANSCRIPTION_BUILTIN = {
      "openai" => "MemoriaServer::Audio::OpenaiTranscription",
      "gemini" => "MemoriaServer::Audio::GeminiTranscription",
    }.freeze

    SPEECH_BUILTIN = {
      "openai" => "MemoriaServer::Audio::OpenaiSpeech",
      "voicevox" => "MemoriaServer::Audio::VoicevoxSpeech",
    }.freeze

    class << self
      def transcription_adapter
        @transcription_adapter ||= load_adapter(
          ENV.fetch("MS_TRANSCRIPTION_ADAPTER", "openai"),
          TRANSCRIPTION_BUILTIN,
          MemoriaServer::Audio::TranscriptionAdapter,
        )
      end

      def speech_adapter
        @speech_adapter ||= load_adapter(
          ENV.fetch("MS_SPEECH_ADAPTER", "openai"),
          SPEECH_BUILTIN,
          MemoriaServer::Audio::SpeechAdapter,
        )
      end

      def transcription_adapter=(instance)
        @transcription_adapter = instance
      end

      def speech_adapter=(instance)
        @speech_adapter = instance
      end

      private

      def load_adapter(kind, builtin_table, base_class)
        klass_name = builtin_table[kind] || kind
        klass = Object.const_get(klass_name)
        instance = klass.new
        unless instance.is_a?(base_class)
          raise MemoriaServer::ContractViolation, "#{klass_name} did not return a #{base_class}"
        end
        instance
      rescue NameError => e
        raise MemoriaServer::Error, "Unknown audio adapter #{kind.inspect} (#{e.message})"
      end
    end
  end
end

require_relative "audio/transcription_adapter"
require_relative "audio/speech_adapter"
require_relative "audio/openai_transcription"
require_relative "audio/openai_speech"
require_relative "audio/voicevox_speech"
require_relative "audio/gemini_transcription"
