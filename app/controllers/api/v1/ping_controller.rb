module Api
  module V1
    class PingController < BaseController
      def show
        render json: {
          ok: true,
          authenticated_as: admin? ? "admin" : "device",
          device: device? ? { slug: current_device.slug, name: current_device.name } : nil,
          server_time: Time.current.iso8601,
        }
      end

      def admin
        require_admin!
        return if performed?
        render json: { ok: true, scope: "admin" }
      end
    end
  end
end
