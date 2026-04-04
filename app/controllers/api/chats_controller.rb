module Api
  class ChatsController < BaseController
    before_action :set_character

    # POST /api/characters/:character_id/chat
    # async (default): returns 202 + job_id for polling
    # sync: pass ?sync=true to get response inline
    def create
      message = params[:message]
      return render json: { error: "message is required" }, status: :bad_request if message.blank?

      if params[:sync] == "true"
        create_sync(message)
      else
        create_async(message)
      end
    rescue => e
      Rails.logger.error("[ChatsController] Error: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      render json: { error: e.message }, status: :internal_server_error
    end

    # POST /api/characters/:character_id/reset
    def reset
      session = ChatSession.find_active(@character, current_user)
      if session
        reflection = session.reset!

        if reflection
          TagProfilingWorker.perform_async(@character.id, reflection[:file_path])
          SleepPhaseWorker.perform_async(@character.id, reflection[:full_log_path]) if reflection[:full_log_path]
        end

        render json: {
          message: "Chat session reset",
          reflection: reflection ? { file: reflection[:base_name], tags: reflection[:tags] } : nil,
        }
      else
        render json: { message: "No active session" }
      end
    end

    private

    def create_sync(message)
      session = ChatSession.find_or_create(@character, current_user)
      result = session.send_message(message)

      render json: {
        response: result[:response],
        usage: result[:usage],
      }
    end

    def create_async(message)
      job_id = SecureRandom.uuid
      chat_result = ChatResult.create!(
        job_id: job_id,
        user: current_user,
        character: @character,
        status: "pending",
        message: message
      )

      ChatWorker.perform_async(chat_result.id)

      render json: {
        job_id: job_id,
        status: "pending",
        poll_url: api_chat_result_path(job_id),
      }, status: :accepted
    end

    def set_character
      @character = current_user.characters.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end
  end
end
