module Api
  module V1
    class CharacterPresenceController < BaseController
      before_action :load_character

      # GET /api/v1/characters/:character_ref/presence
      # 認可：device key でも admin key でも可（読み取り）
      def show
        presence = Presence.find_by(character_id: @character.id)
        active_device = presence&.active_device

        render json: {
          character: { id: @character.id, slug: @character.vault_dir_name, name: @character.name },
          active_device: active_device ? { slug: active_device.slug, name: active_device.name } : nil,
          since: presence&.since&.iso8601
        }
      end

      # POST /api/v1/characters/:character_ref/transfer
      # body: { "to_device": "<slug>", "reason": "..." }
      # 認可：admin、または device key で「自デバイスに呼ぶ」場合のみ
      def transfer
        to_slug = params[:to_device].to_s
        return bad_request!("to_device is required") if to_slug.blank?

        target = Device.find_by(slug: to_slug)
        return not_found!("device not found: #{to_slug}") unless target

        unless can_transfer_to?(target)
          return forbidden!("device key can only transfer character to its own device")
        end

        reason = params[:reason].presence || (admin? ? "admin_request" : "user_requested")

        result = MemoriaServer::PresenceManager.transfer!(
          character: @character,
          to_device: target,
          reason: reason,
        )

        render json: {
          ok: true,
          transferred: result[:transferred],
          from_device_slug: result[:from_device]&.slug,
          to_device_slug: result[:to_device].slug,
          reason: reason
        }
      end

      private

      def load_character
        @character = find_character_by_ref(params[:character_ref])
        not_found!("character not found: #{params[:character_ref]}") unless @character
      end

      def can_transfer_to?(target)
        return true if admin?
        return true if device? && current_device.id == target.id
        false
      end
    end
  end
end
