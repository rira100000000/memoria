module Api
  module V1
    # アダプタ起点 push（utter / action / conversation boundary）の HTTP ファサード。
    # アダプタが Ruby コードから直接 `MemoriaServer.utter` 等を呼べる場合はそちらを使うが、
    # 他言語の HTTP アダプタや外部スクリプトはこのエンドポイント経由で叩く。
    class CharacterActionsController < BaseController
      before_action :load_character

      # POST /api/v1/characters/:character_ref/utter
      # body: { "text": "...", "emotion": "happy", "metadata": {} }
      # 認可：admin のみ（アダプタ・運用者からの発火）
      def utter
        require_admin!
        return if performed?

        text = params[:text].to_s
        return bad_request!("text is required") if text.blank?

        MemoriaServer::Push.utter(
          character_id: @character.id,
          text: text,
          emotion: params[:emotion],
          metadata: params[:metadata]&.to_unsafe_h || {},
        )

        render json: { ok: true }
      rescue MemoriaServer::NoActiveDevice => e
        render json: error_payload("no_active_device", e.message), status: :conflict
      end

      # POST /api/v1/characters/:character_ref/action
      # body: { "command": "dance", "params": { "duration_sec": 10 } }
      def action
        require_admin!
        return if performed?

        command = params[:command].to_s
        return bad_request!("command is required") if command.blank?

        MemoriaServer::Push.action(
          character_id: @character.id,
          command: command,
          params: params[:params]&.to_unsafe_h || {},
        )

        render json: { ok: true }
      rescue MemoriaServer::NoActiveDevice => e
        render json: error_payload("no_active_device", e.message), status: :conflict
      end

      # POST /api/v1/characters/:character_ref/conversation/boundary
      # body: { "reason": "user_requested" }
      # 認可：admin、または device key（アクティブなデバイスからのみ）
      def boundary
        unless can_signal_boundary?
          return forbidden!("only the active device or admin can signal a boundary")
        end

        reason = params[:reason].presence || "user_requested"
        result = MemoriaServer.adapter.on_boundary(
          character_id: @character.id,
          reason: reason,
        )

        render json: {
          ok: true,
          reason: reason,
          had_active_session: !result.nil?
        }
      end

      private

      def load_character
        @character = find_character_by_ref(params[:character_ref])
        not_found!("character not found: #{params[:character_ref]}") unless @character
      end

      def can_signal_boundary?
        return true if admin?
        return false unless device?
        active = Presence.find_by(character_id: @character.id)&.active_device_id
        active == current_device.id
      end
    end
  end
end
