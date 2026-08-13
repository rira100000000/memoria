module MemoriaServer
  module Audio
    # 音声→テキスト変換アダプタの抽象。
    # サブクラスは #transcribe を実装。バックエンド差し替え（OpenAI / faster-whisper / Whisper.cpp）の境界。
    class TranscriptionAdapter
      # @param audio_io [IO] 音声ファイル（multipart で受け取った Tempfile 等）
      # @param filename [String] 拡張子判定用（例 "voice.wav"）
      # @param model [String, nil] クライアントが指定したモデル名（実装側で無視可）
      # @param language [String, nil] ISO 639-1 等の言語ヒント（"ja" 等）
      # @param prompt [String, nil] 文脈ヒント（OpenAI 互換）
      # @param temperature [Float, nil]
      # @param response_format [String, nil] "json" / "text" / "verbose_json" / "srt" / "vtt"。実装側で扱える形式のみ尊重
      # @return [Hash] { text: String, raw: Hash, response_format: "json" }
      def transcribe(audio_io:, filename:, model: nil, language: nil, prompt: nil, temperature: nil, response_format: nil)
        raise NotImplementedError, "#{self.class} must implement #transcribe"
      end
    end
  end
end
