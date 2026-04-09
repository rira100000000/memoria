module Api
  class ReadingController < BaseController
    before_action :set_character

    # POST /api/characters/:id/reading/start
    def start
      llm_client = LlmClient.new
      result = if params[:work_id].present?
        Reading::AozoraTool.execute(
          action: "read", work_id: params[:work_id],
          character: @character, llm_client: llm_client
        )
      else
        Reading::AozoraTool.execute(
          action: "discover", genre: params[:genre],
          character: @character, llm_client: llm_client
        )
      end
      render json: result
    end

    # POST /api/characters/:id/reading/continue
    def continue
      result = Reading::AozoraTool.execute(
        action: "continue", character: @character
      )
      render json: result
    end

    # GET /api/characters/:id/reading/current
    def current
      rp = @character.current_reading
      if rp
        render json: {
          id: rp.id,
          title: rp.title,
          author: rp.author,
          current_position: rp.current_position,
          total_length: rp.total_length,
          status: rp.status,
          chunk_boundaries: rp.parsed_chunk_boundaries,
          notes: rp.parsed_notes,
        }
      else
        render json: { error: "no current reading" }, status: :not_found
      end
    end

    # GET /api/aozora/search?q=...
    def search
      results = Reading::AozoraCatalog.search(params[:q].to_s)
      render json: { results: results }
    end

    private

    def set_character
      @character = current_user.characters.find(params[:character_id] || params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end
  end
end
