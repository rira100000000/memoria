module Api
  module V1
    # Discord の bot がサーバーに返答を頼む入口。bot 専用の鍵（MEMORIA_BOT_TOKEN）だけを通す。
    # Api::V1::BaseController は継承しない（端末の鍵・管理キーを通さないため。逆に bot の鍵も、他の入口では通らない）。
    #
    # キャラクターは、bot からは受け取らず、Discord のチャンネル ID からサーバーが引く。
    # 経路（platform）は :discord に固定する。送り手の許可（DISCORD_ALLOWED_USER_IDS）もここで確かめる。
    class DiscordRepliesController < ApplicationController
      include ActionController::Live

      # 同じキャラクターの別の返答を待つ上限（秒）。puma のスレッドを長く占有しないよう、会話の既定（30分）より短くする
      TURN_WAIT = Integer(ENV.fetch("DISCORD_TURN_WAIT", 300))

      before_action :authenticate_bot!

      def create
        text = params[:text].to_s
        return render_error(:bad_request, "text is required") if text.strip.empty?
        unless MemoriaServer::DiscordProtocol.allowed_user?(allowed_user_ids, params[:author_id])
          return render_error(:forbidden, "user not allowed")
        end

        character = ChannelBinding.find_character_for_discord(params[:channel_id])
        return render_error(:not_found, "channel not bound") unless character

        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
        MemoriaServer::DiscordReplyStream.new(writer: response.stream)
          .run(character: character, text: text, channel_name: "Discord ##{params[:channel_name]}", turn_wait: TURN_WAIT)
      ensure
        response.stream.close
      end

      private

      def authenticate_bot!
        return if MemoriaServer::DiscordBotAuth.authorized?(request.headers["Authorization"], MemoriaServer::DiscordBotToken.current)

        render_error(:unauthorized, "invalid bot token")
      end

      def allowed_user_ids
        MemoriaServer::DiscordProtocol.parse_ids(ENV["DISCORD_ALLOWED_USER_IDS"])
      end

      def render_error(status, message)
        render json: { error: { code: status.to_s, message: message } }, status: status
      end
    end
  end
end
