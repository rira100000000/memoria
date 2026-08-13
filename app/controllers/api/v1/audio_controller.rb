module Api
  module V1
    # OpenAI 互換 Audio API。
    # - POST /v1/audio/transcriptions  (multipart/form-data: file, model, language, ...)
    # - POST /v1/audio/speech          (JSON: input, model, voice, response_format, speed)
    #
    # 実装は MemoriaServer::Audio.{transcription_adapter, speech_adapter} に委譲。
    # 環境変数 MS_TRANSCRIPTION_ADAPTER / MS_SPEECH_ADAPTER で切替可能（既定は openai）。
    class AudioController < BaseController
      def transcriptions
        return forbidden!("device key required") unless device?

        file = params[:file]
        return bad_request!("file is required (multipart)") unless file.respond_to?(:tempfile)

        result = MemoriaServer::Audio.transcription_adapter.transcribe(
          audio_io: file.tempfile,
          filename: file.original_filename.to_s,
          model: params[:model],
          language: params[:language],
          prompt: params[:prompt],
          temperature: params[:temperature],
          response_format: params[:response_format],
        )

        if params[:response_format].to_s == "text"
          render plain: result[:text]
        else
          render json: { text: result[:text] }.merge(result[:raw].is_a?(Hash) ? result[:raw].slice("language", "duration", "segments") : {})
        end
      rescue MemoriaServer::Error => e
        render json: error_payload("audio_error", e.message), status: :bad_gateway
      end

      def speech
        return forbidden!("device key required") unless device?

        body = request.request_parameters
        input = body[:input] || body["input"]
        return bad_request!("input is required") if input.to_s.empty?

        result = MemoriaServer::Audio.speech_adapter.synthesize(
          input: input,
          voice: body[:voice] || body["voice"],
          model: body[:model] || body["model"],
          response_format: body[:response_format] || body["response_format"] || "mp3",
          speed: body[:speed] || body["speed"],
        )

        send_data result[:audio], type: result[:content_type], disposition: "inline"
      rescue MemoriaServer::Error => e
        render json: error_payload("audio_error", e.message), status: :bad_gateway
      end
    end
  end
end
