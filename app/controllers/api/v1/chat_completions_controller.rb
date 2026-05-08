module Api
  module V1
    # OpenAI Chat Completions 互換エンドポイント。
    # クライアントは `model: "memoria/<character_id_or_slug>"` で対象キャラを指定する。
    # Phase 1 仕様：
    # - device key 認証必須（管理キーは不可）
    # - presence の寛容モード自動 transfer
    # - stream: true で SSE、false で集約 JSON
    # - tools / vision / system prompt はパススルーでアダプタへ
    class ChatCompletionsController < BaseController
      include ActionController::Live

      def create
        return forbidden!("device key required for chat completions") unless device?

        model_str = params[:model].to_s
        unless model_str.start_with?("memoria/")
          return bad_request!("model must be in form 'memoria/<character_id>'. got: #{model_str.inspect}")
        end

        char_ref = model_str.sub(/^memoria\//, "")
        character = find_character_by_ref(char_ref)
        return not_found!("character not found: #{char_ref}") unless character

        ensure_presence!(character, current_device)

        ctx = MemoriaServer::ContextBuilder.build(
          character: character,
          device: current_device,
          payload: request_payload,
          last_interaction_at: presence_since(character),
        )

        if streaming?
          stream_response(character: character, context: ctx)
        else
          batch_response(character: character, context: ctx)
        end
      rescue ActiveRecord::RecordNotFound => e
        render json: error_payload("not_found", e.message), status: :not_found
      rescue MemoriaServer::Error => e
        render json: error_payload("memoria_server_error", e.message), status: :bad_request
      end

      private

      # OpenAI クライアントが送ってくるリクエストボディを Hash で取得。
      # `params` は wrap-paramsで :chat_completion キーが追加されることがあるので、
      # 安全のため request.request_parameters を使う。
      def request_payload
        request.request_parameters
      end

      def streaming?
        ActiveModel::Type::Boolean.new.cast(params[:stream])
      end

# 寛容モード：要求された character がこの device に active でなければ自動 transfer。
      def ensure_presence!(character, device)
        presence = Presence.find_or_create_by!(character: character)
        return if presence.active_device_id == device.id

        MemoriaServer::PresenceManager.transfer!(
          character: character,
          to_device: device,
          reason: presence.active_device_id ? "displaced_by_call" : "first_assignment",
        )
      end

      def presence_since(character)
        Presence.find_by(character_id: character.id)&.since
      end

      def stream_response(character:, context:)
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
        completion_id = "chatcmpl-#{SecureRandom.hex(12)}"
        created = Time.current.to_i
        model_label = "memoria/#{character.vault_dir_name}"

        adapter = MemoriaServer.adapter
        first_delta = true

        adapter.respond(context[:current_input], context: context).each do |chunk|
          if chunk[:delta]
            delta_payload = { content: chunk[:delta] }
            delta_payload[:role] = "assistant" if first_delta
            delta_payload[:x_memoria] = { emotion: chunk[:emotion] } if chunk[:emotion]
            first_delta = false
            write_sse(completion_id, created, model_label, delta: delta_payload, finish_reason: nil)
          elsif chunk[:tool_calls]
            write_sse(completion_id, created, model_label, delta: { tool_calls: chunk[:tool_calls] }, finish_reason: nil)
          elsif chunk[:done]
            write_sse(completion_id, created, model_label, delta: {}, finish_reason: "stop")
            response.stream.write("data: [DONE]\n\n")
          end
        end
      rescue IOError, Errno::EPIPE
        # クライアント切断は無視
      ensure
        response.stream.close rescue nil
      end

      def write_sse(completion_id, created, model_label, delta:, finish_reason:)
        body = {
          id: completion_id,
          object: "chat.completion.chunk",
          created: created,
          model: model_label,
          choices: [{
            index: 0,
            delta: delta,
            finish_reason: finish_reason,
          }],
        }
        response.stream.write("data: #{body.to_json}\n\n")
      end

      def batch_response(character:, context:)
        full_text = +""
        emotion = nil
        usage = nil
        tool_calls = nil

        MemoriaServer.adapter.respond(context[:current_input], context: context).each do |chunk|
          if chunk[:delta]
            full_text << chunk[:delta]
            emotion ||= chunk[:emotion]
          elsif chunk[:tool_calls]
            tool_calls ||= []
            tool_calls.concat(Array(chunk[:tool_calls]))
          elsif chunk[:done]
            usage = chunk.dig(:metadata, :usage)
          end
        end

        message = { role: "assistant", content: full_text }
        message[:x_memoria] = { emotion: emotion } if emotion
        message[:tool_calls] = tool_calls if tool_calls

        body = {
          id: "chatcmpl-#{SecureRandom.hex(12)}",
          object: "chat.completion",
          created: Time.current.to_i,
          model: "memoria/#{character.vault_dir_name}",
          choices: [{
            index: 0,
            message: message,
            finish_reason: tool_calls ? "tool_calls" : "stop",
          }],
        }
        body[:usage] = usage_to_openai(usage) if usage
        render json: body
      end

      def usage_to_openai(u)
        return nil unless u.is_a?(Hash)
        {
          prompt_tokens: u[:input_tokens] || u["input_tokens"] || 0,
          completion_tokens: u[:output_tokens] || u["output_tokens"] || 0,
          total_tokens: u[:total_tokens] || u["total_tokens"] || 0,
        }
      end
    end
  end
end
