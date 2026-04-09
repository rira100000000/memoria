module Api
  class MemoriesController < BaseController
    before_action :set_character

    # POST /api/characters/:id/memories/recall { query }
    def recall
      query = params[:query].to_s
      return render json: { error: "query required" }, status: :bad_request if query.blank?

      vault = MemoriaCore::VaultManager.new(@character.vault_path)
      vault.ensure_structure!
      llm_client = LlmClient.new
      embedding_store = MemoriaCore::EmbeddingStore.new(vault, llm_client)
      embedding_store.initialize!
      retriever = MemoriaCore::ContextRetriever.new(vault, embedding_store)

      result = retriever.retrieve(query)
      render json: { context: result[:llm_context_prompt] }
    end

    private

    def set_character
      @character = current_user.characters.find(params[:character_id] || params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end
  end
end
