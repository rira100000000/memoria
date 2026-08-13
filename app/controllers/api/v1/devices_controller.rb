module Api
  module V1
    class DevicesController < BaseController
      include ActionController::Live

      # GET /api/v1/devices — 管理キー必須（全デバイス一覧）
      def index
        require_admin!
        return if performed?

        render json: {
          devices: Device.order(:slug).map { |d| device_summary(d) }
        }
      end

      # GET /api/v1/devices/:slug — 自デバイス情報 or 管理キーで任意デバイス
      def show
        device = Device.find_by(slug: params[:slug])
        return not_found!("device not found: #{params[:slug]}") unless device
        return forbidden!("you can only inspect your own device") unless can_access_device?(device)

        render json: device_detail(device)
      end

      # POST /api/v1/devices/:slug/heartbeat — デバイスキー必須（自分のみ）
      def heartbeat
        device = Device.find_by(slug: params[:slug])
        return not_found!("device not found: #{params[:slug]}") unless device
        return forbidden!("you can only heartbeat your own device") unless device? && current_device.id == device.id

        device.heartbeat!

        present = Presence.find_by(active_device_id: device.id)
        active_character = present ? character_summary(present.character) : nil

        render json: {
          ok: true,
          device: { slug: device.slug, name: device.name, last_heartbeat_at: device.reload.last_heartbeat_at&.iso8601 },
          active_character: active_character
        }
      end

      # GET /api/v1/devices/:slug/events — SSE 常駐イベントチャンネル
      # デバイスキー必須（自デバイスのみ）。Redis pub/sub の `memoria:device:<slug>:events` を購読し、
      # presence.arrived / presence.departed / utter / action を流す。
      def events
        device = Device.find_by(slug: params[:slug])
        return not_found!("device not found: #{params[:slug]}") unless device
        unless device? && current_device.id == device.id
          return forbidden!("device key required for own device events stream")
        end

        stream_device_events(device)
      end

      # GET /api/v1/me/events — 認証されたデバイスキーが指す自デバイスのイベントを購読する。
      # クライアントが slug を知らなくても device_key だけで購読できる便利エンドポイント。
      def my_events
        return forbidden!("device key required for /me/events") unless device?
        stream_device_events(current_device)
      end

      private

      # 指定 device の Redis pub/sub チャンネルを購読し、SSE でクライアントに流す。
      # events / my_events から共通利用される。
      #
      # クライアント切断検知のため、定期的に keepalive コメント行を書き込む。
      # write が IOError を投げたらクライアント側がいなくなったと判断し、購読解除する。
      # （イベントが流れない静かな接続でもスレッドリークしないようにする）
      def stream_device_events(device)
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
        response.headers["Connection"] = "keep-alive"

        channel = MemoriaServer::Push.channel_for(device)
        sub = MemoriaServer::RedisClient.new_subscriber

        # 接続直後にコメント行を送って TCP プロキシのバッファリングをフラッシュさせる
        response.stream.write(": connected to #{device.slug}\n\n")

        # keepalive スレッド：15秒ごとに `: ping\n\n` を書き込み、書けなくなったら unsubscribe を依頼
        keepalive_thread = Thread.new do
          loop do
            sleep 15
            begin
              response.stream.write(": ping\n\n")
            rescue IOError, Errno::EPIPE
              sub.unsubscribe rescue nil
              break
            end
          end
        end

        sub.subscribe(channel) do |on|
          on.message do |_chan, raw|
            begin
              payload = JSON.parse(raw)
              event_name = payload["event"] || "message"
              data = payload["data"] || {}
              response.stream.write("event: #{event_name}\n")
              response.stream.write("data: #{data.to_json}\n\n")
            rescue IOError, Errno::EPIPE
              sub.unsubscribe
            rescue JSON::ParserError
              # 不正な payload は黙って捨てる
            end
          end
        end
      rescue IOError, Errno::EPIPE
        # client disconnected — silent
      ensure
        keepalive_thread&.kill rescue nil
        sub&.close rescue nil
        response.stream.close rescue nil
      end

      def can_access_device?(device)
        return true if admin?
        return true if device? && current_device.id == device.id
        false
      end

      def device_summary(device)
        {
          slug: device.slug,
          name: device.name,
          capabilities: device.capabilities,
          last_heartbeat_at: device.last_heartbeat_at&.iso8601,
          active_character_id: Presence.find_by(active_device_id: device.id)&.character_id
        }
      end

      def device_detail(device)
        present = Presence.find_by(active_device_id: device.id)
        {
          slug: device.slug,
          name: device.name,
          capabilities: device.capabilities,
          last_heartbeat_at: device.last_heartbeat_at&.iso8601,
          active_character: present ? character_summary(present.character) : nil,
          recent_transfers: device.outgoing_transfers.order(occurred_at: :desc).limit(5).map { |t| transfer_summary(t) } +
                            device.incoming_transfers.order(occurred_at: :desc).limit(5).map { |t| transfer_summary(t) }
        }
      end

      def character_summary(character)
        {
          id: character.id,
          slug: character.vault_dir_name,
          name: character.name
        }
      end

      def transfer_summary(t)
        {
          character_id: t.character_id,
          from_device_slug: t.from_device&.slug,
          to_device_slug: t.to_device&.slug,
          reason: t.reason,
          occurred_at: t.occurred_at.iso8601
        }
      end
    end
  end
end
