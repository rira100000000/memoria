module Api
  module V1
    # MemoriaServer v1 API 基底コントローラ。
    # 認証は管理キー (AdminKey) または デバイスキー (DeviceKey) の Bearer 方式。
    # 既存 Api::BaseController (User.api_token 認証) とは独立。
    class BaseController < ApplicationController
      before_action :authenticate!

      # サブクラスで `require_admin!` を before_action に指定すると管理キー必須にできる。
      attr_reader :current_device, :current_admin_key

      def admin?
        @current_admin_key.present?
      end

      def device?
        @current_device.present?
      end

      private

      def authenticate!
        token = bearer_token
        return unauthorized!("missing bearer token") if token.blank?

        if (device_key = DeviceKey.find_by_plain_key(token))
          @current_device = device_key.device
          @current_device_key = device_key
          device_key.touch_used!
          return
        end

        if (admin_key = AdminKey.find_by_plain_key(token))
          @current_admin_key = admin_key
          admin_key.touch_used!
          return
        end

        unauthorized!("invalid bearer token")
      end

      def require_admin!
        return if admin?
        forbidden!("admin key required")
      end

      def bearer_token
        request.headers["Authorization"]&.sub(/^Bearer\s+/i, "")
      end

      # 数値なら id、それ以外は vault_dir_name で character を引く。
      def find_character_by_ref(ref)
        return nil if ref.blank?
        if ref.match?(/\A\d+\z/)
          Character.find_by(id: ref.to_i)
        else
          Character.find_by(vault_dir_name: ref)
        end
      end

      def unauthorized!(message)
        render json: error_payload("unauthorized", message), status: :unauthorized
      end

      def forbidden!(message)
        render json: error_payload("forbidden", message), status: :forbidden
      end

      def not_found!(message = "not found")
        render json: error_payload("not_found", message), status: :not_found
      end

      def bad_request!(message)
        render json: error_payload("bad_request", message), status: :bad_request
      end

      # OpenAI互換のエラー形式に揃える
      # { error: { type:, message: } }
      def error_payload(type, message)
        { error: { type: type, message: message } }
      end
    end
  end
end
