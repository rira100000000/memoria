module Api
  class SnapshotsController < BaseController
    before_action :set_character
    before_action :set_versioning

    # GET /api/characters/:id/snapshots
    def index
      render json: {
        current_branch: @versioning.current_branch,
        head: @versioning.head_sha,
        history: @versioning.recent_history(50),
      }
    end

    # POST /api/characters/:id/snapshots { label }
    def create
      label = params[:label].to_s
      label = "manual snapshot" if label.blank?

      if @versioning.commit_snapshot("manual", label)
        render json: { sha: @versioning.head_sha, label: label }, status: :created
      else
        render json: { sha: @versioning.head_sha, message: "no changes to commit" }
      end
    end

    # POST /api/characters/:id/snapshots/restore { sha }
    def restore
      sha = params[:sha].to_s
      return render json: { error: "sha required" }, status: :bad_request if sha.blank?

      if @versioning.rollback_to(sha)
        render json: { restored_to: sha, current: @versioning.head_sha }
      else
        render json: { error: "restore failed" }, status: :unprocessable_entity
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
