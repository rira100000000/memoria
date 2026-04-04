module Api
  class SummarizeController < BaseController
    before_action :set_character

    # POST /api/characters/:character_id/summarize
    # フルログテキストを受け取り、サマリーノート生成を非同期実行
    #
    # Params:
    #   conversation_text: 会話ログ全文（必須）
    #   full_log_ref: FullLogファイル名（任意）
    #   full_log_path: FullLogの相対パス（任意、SleepPhase用）
    #   timestamp: タイムスタンプ（任意、デフォルト: 現在時刻）
    def create
      text = params[:conversation_text]
      return render json: { error: "conversation_text is required" }, status: :bad_request if text.blank?

      job_id = SecureRandom.uuid
      chat_result = ChatResult.create!(
        job_id: job_id,
        user: current_user,
        character: @character,
        status: "pending",
        message: text,
        usage: {
          "full_log_ref" => params[:full_log_ref],
          "full_log_path" => params[:full_log_path],
          "timestamp" => params[:timestamp],
        }
      )

      SummarizeWorker.perform_async(chat_result.id)

      render json: {
        job_id: job_id,
        status: "pending",
        poll_url: api_chat_result_path(job_id),
      }, status: :accepted
    end

    private

    def set_character
      @character = current_user.characters.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end
  end
end
