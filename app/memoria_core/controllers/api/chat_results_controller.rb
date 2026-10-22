module Api
  class ChatResultsController < BaseController
    # GET /api/chat_results/:job_id
    def show
      chat_result = current_user.chat_results.find_by!(job_id: params[:id])

      case chat_result.status
      when "completed"
        render json: {
          status: "completed",
          response: chat_result.response,
          usage: chat_result.usage,
        }
      when "failed"
        render json: {
          status: "failed",
          error: chat_result.error_message,
        }
      else
        render json: {
          status: chat_result.status,
        }
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat result not found" }, status: :not_found
    end
  end
end
