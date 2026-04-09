module Api
  class BranchesController < BaseController
    before_action :set_character
    before_action :set_versioning

    # GET /api/characters/:id/branches
    def index
      render json: {
        current: @versioning.current_branch,
        branches: @versioning.list_branches,
      }
    end

    # POST /api/characters/:id/branches { name }
    def create
      name = params[:name].to_s
      return render json: { error: "name required" }, status: :bad_request if name.blank?

      if @versioning.create_branch(name)
        render json: { branch: name, current: @versioning.current_branch }, status: :created
      else
        render json: { error: "failed to create branch" }, status: :unprocessable_entity
      end
    end

    # POST /api/characters/:id/branches/:name/checkout
    def checkout
      if @versioning.checkout_branch(params[:name])
        render json: { current: @versioning.current_branch }
      else
        render json: { error: "checkout failed" }, status: :unprocessable_entity
      end
    end

    # POST /api/characters/:id/branches/:name/merge { into }
    def merge
      into = params[:into].to_s
      return render json: { error: "into required" }, status: :bad_request if into.blank?

      if @versioning.merge_branch(params[:name], into: into)
        render json: { merged: params[:name], into: into }
      else
        render json: { error: "merge failed" }, status: :unprocessable_entity
      end
    end

    # DELETE /api/characters/:id/branches/:name
    def destroy
      if @versioning.delete_branch(params[:name])
        head :no_content
      else
        render json: { error: "delete failed" }, status: :unprocessable_entity
      end
    end

    private

    def set_character
      @character = current_user.characters.find(params[:character_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end

    def set_versioning
      vault = MemoriaCore::VaultManager.new(@character.vault_path)
      vault.ensure_structure!
      @versioning = vault.versioning
    end
  end
end
