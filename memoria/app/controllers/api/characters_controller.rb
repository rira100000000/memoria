module Api
  class CharactersController < BaseController
    before_action :set_character, only: [:show, :update, :destroy]

    def index
      characters = current_user.characters
      render json: characters.map { |c| character_json(c) }
    end

    def show
      render json: character_json(@character)
    end

    def create
      character = current_user.characters.build(character_params)
      if character.save
        render json: character_json(character), status: :created
      else
        render json: { errors: character.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      if @character.update(character_params)
        render json: character_json(@character)
      else
        render json: { errors: @character.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      @character.destroy
      head :no_content
    end

    private

    def set_character
      @character = current_user.characters.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Character not found" }, status: :not_found
    end

    def character_params
      params.require(:character).permit(:name, :system_prompt, :thinking_loop_enabled, :thinking_loop_interval_minutes)
    end

    def character_json(c)
      {
        id: c.id,
        name: c.name,
        system_prompt: c.system_prompt,
        vault_dir_name: c.vault_dir_name,
        thinking_loop_enabled: c.thinking_loop_enabled,
        thinking_loop_interval_minutes: c.thinking_loop_interval_minutes,
        created_at: c.created_at,
        updated_at: c.updated_at,
      }
    end
  end
end
