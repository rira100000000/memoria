module Api
  module V1
    # 端末が、自分の capabilities（出せる表情・エモートなど）を登録する。端末の鍵だけを通す（自分の登録だけを変える）。
    #   GET /api/v1/me/capabilities  いまの登録
    #   PUT /api/v1/me/capabilities  { "capabilities": { "expression": { "faces": [...], "emotes": [...] } } }
    class DeviceCapabilitiesController < BaseController
      before_action :require_device!

      def show
        render json: { capabilities: current_device.capabilities }
      end

      def update
        result = MemoriaServer::DeviceCapabilities.register(current_device.capabilities, incoming)
        return render json: { error: { code: "invalid_capabilities", message: result.errors } }, status: :unprocessable_entity if result.errors.any?

        current_device.update!(capabilities: result.capabilities)
        render json: { capabilities: result.capabilities, ignored: result.ignored, dropped: result.dropped }
      end

      private

      def require_device!
        forbidden!("device key required") unless device?
      end

      def incoming
        value = request.request_parameters["capabilities"]
        value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      end
    end
  end
end
