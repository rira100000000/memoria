require "faraday"
require "json"

module MemoriaServer
  module Audio
    # VOICEVOX エンジンへ proxy する speech adapter。
    # 2-step API: audio_query → synthesis。WAV のみ返す（OpenAI TTS のような mp3/opus には非対応）。
    # 呼び出し側が response_format に何を指定しても WAV を返す（Stack-chan は WAV を期待）。
    #
    # 環境変数:
    #   - VOICEVOX_URL: デフォルト http://localhost:50021
    #   - VOICEVOX_SPEAKER: デフォルト "1" (四国めたん・あまあま)
    #
    # voice 引数: 数字文字列 (例 "3") を VOICEVOX speaker ID として解釈。OpenAI voice 名
    # ("alloy" 等) が来たら default_speaker にフォールバック。
    class VoicevoxSpeech < SpeechAdapter
      DEFAULT_BASE = "http://localhost:50021".freeze
      DEFAULT_SPEAKER = "1".freeze

      def initialize(base_url: ENV["VOICEVOX_URL"], default_speaker: ENV["VOICEVOX_SPEAKER"])
        @base_url = (base_url.presence || DEFAULT_BASE).chomp("/")
        @default_speaker = (default_speaker.presence || DEFAULT_SPEAKER).to_s
      end

      def synthesize(input:, voice: nil, model: nil, response_format: "wav", speed: nil)
        speaker = voice.to_s.match?(/\A\d+\z/) ? voice.to_s : @default_speaker

        # Step 1: audio_query
        q_resp = client.post("/audio_query") do |req|
          req.params["speaker"] = speaker
          req.params["text"] = input
        end
        unless q_resp.success?
          raise MemoriaServer::Error,
                "VOICEVOX audio_query failed: status=#{q_resp.status} body=#{q_resp.body[0, 200]}"
        end

        query = JSON.parse(q_resp.body)
        query["speedScale"] = speed.to_f if speed.present?

        # Step 2: synthesis
        s_resp = client.post("/synthesis") do |req|
          req.params["speaker"] = speaker
          req.headers["Content-Type"] = "application/json"
          req.body = query.to_json
        end
        unless s_resp.success?
          raise MemoriaServer::Error,
                "VOICEVOX synthesis failed: status=#{s_resp.status} body=#{s_resp.body[0, 200]}"
        end

        { audio: s_resp.body, content_type: "audio/wav" }
      end

      private

      def client
        @client ||= Faraday.new(url: @base_url) do |f|
          f.adapter Faraday.default_adapter
          f.options.timeout = 60
        end
      end
    end
  end
end
