module MemoriaServer
  module Audio
    # テキスト→音声合成アダプタの抽象。
    # サブクラスは #synthesize を実装。バックエンド差し替え（OpenAI TTS / AivisSpeech / VOICEVOX）の境界。
    class SpeechAdapter
      # @param input [String] 合成するテキスト
      # @param voice [String, nil] バックエンド固有の話者識別子（OpenAI: alloy / nova etc.）
      # @param model [String, nil] バックエンド固有のモデル名（OpenAI: tts-1, tts-1-hd 等）
      # @param response_format [String] "mp3" / "opus" / "aac" / "flac" / "wav" / "pcm"
      # @param speed [Float, nil] 0.25..4.0 等、バックエンドが対応する範囲
      # @return [Hash] { audio: String(binary), content_type: String }
      def synthesize(input:, voice: nil, model: nil, response_format: "mp3", speed: nil)
        raise NotImplementedError, "#{self.class} must implement #synthesize"
      end
    end
  end
end
