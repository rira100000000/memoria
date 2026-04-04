module Api
  class PendingMessagesController < BaseController
    # GET /api/pending_messages
    # 未読の自発的メッセージ一覧を取得
    def index
      messages = current_user.pending_messages.unread.order(created_at: :desc)

      if params[:character_id].present?
        messages = messages.where(character_id: params[:character_id])
      end

      render json: messages.map { |m|
        {
          id: m.id,
          character_id: m.character_id,
          character_name: m.character.name,
          trigger_type: m.trigger_type,
          content: m.content,
          topic_tag: m.topic_tag,
          status: m.status,
          created_at: m.created_at,
        }
      }
    end

    # PATCH /api/pending_messages/:id/read
    def read
      message = current_user.pending_messages.find(params[:id])
      message.mark_read!
      render json: { status: "read" }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Message not found" }, status: :not_found
    end
  end
end
