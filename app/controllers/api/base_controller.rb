module Api
  class BaseController < ApplicationController
    before_action :authenticate!

    private

    def authenticate!
      token = request.headers["Authorization"]&.sub(/^Bearer\s+/, "")
      @current_user = User.find_by(api_token: token)
      render json: { error: "Unauthorized" }, status: :unauthorized unless @current_user
    end

    attr_reader :current_user
  end
end
