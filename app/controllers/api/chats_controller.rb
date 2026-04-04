module Api
  class ChatsController < BaseController
    before_action :set_character

    # POST /api/characters/:character_id/chat
    def create
      message = params[:message]
      return render json: { error: "message is required" }, status: :bad_request if message.blank?

      session = find_or_create_session
      result = session.send_message(message)

      render json: {
        response: result[:response],
        usage: result[:usage],
      }
    rescue => e
      Rails.logger.error("[ChatsController] Error: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      render json: { error: e.message }, status: :internal_server_error
    end

    # POST /api/characters/:character_id/reset
    def reset
      session = find_session
      if session
        reflection = session.reset!
        remove_session
        render json: {
          message: "Chat session reset",
          reflection: reflection ? { file: reflection[:base_name], tags: reflection[:tags] } : nil,
        }
      else
        render json: { message: "No active session" }
      end
    end

    private

    def set_character
      @character = current_user.characters.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end

    def session_key
      "chat_session_#{current_user.id}_#{@character.id}"
    end

    def find_or_create_session
      # セッションはインメモリで管理（プロセス内シングルトン）
      ChatSessionStore.instance.fetch(session_key) do
        ChatSession.new(@character)
      end
    end

    def find_session
      ChatSessionStore.instance.get(session_key)
    end

    def remove_session
      ChatSessionStore.instance.delete(session_key)
    end
  end
end
