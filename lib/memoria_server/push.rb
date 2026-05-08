require "json"

module MemoriaServer
  # アダプタ起点で発火するイベントを Redis pub/sub 経由でデバイスへ届ける。
  #
  # 各デバイスごとにチャンネル `memoria:device:<slug>:events` を持つ。
  # SSE エンドポイント（ステージ4で実装）がこのチャンネルを購読し、クライアントへ流す。
  module Push
    module_function

    # キャラの現在のデバイスに発話を届ける。
    # @param character_id [Integer]
    # @param text [String]
    # @param emotion [String, Symbol, nil]
    # @param metadata [Hash]
    # @raise [NoActiveDevice] 現在 active なデバイスがない場合
    def utter(character_id:, text:, emotion: nil, metadata: {})
      character = Character.find(character_id)
      device = require_active_device!(character)
      publish_to_device(device, "utter", {
        character_id: character.id,
        text: text,
        emotion: emotion,
        metadata: metadata,
      })
    end

    # キャラを別デバイスへ移動させる。プレゼンスを atomic に切り替え、
    # 旧デバイスへ departed、新デバイスへ arrived を push する。
    # @param character_id [Integer]
    # @param to_device [String, Device] デバイス slug or Device インスタンス
    # @param reason [String]
    def transfer(character_id:, to_device:, reason: "user_requested")
      character = Character.find(character_id)
      target = resolve_device(to_device)
      raise Error, "destination device not found: #{to_device.inspect}" unless target

      PresenceManager.transfer!(character: character, to_device: target, reason: reason)
    end

    # キャラがいるデバイスに行動コマンドを届ける（"dance" 等）。
    def action(character_id:, command:, params: {})
      character = Character.find(character_id)
      device = require_active_device!(character)
      publish_to_device(device, "action", {
        character_id: character.id,
        command: command,
        params: params,
      })
    end

    # 内部 API：デバイスのチャンネルへ event を publish する。
    # PresenceManager や他の MS 内部からも使う。
    def publish_to_device(device, event_type, payload)
      raise ArgumentError, "device required" unless device
      MemoriaServer::RedisClient.publisher.publish(
        channel_for(device),
        { event: event_type, data: payload, at: Time.current.iso8601 }.to_json,
      )
    end

    def channel_for(device)
      "memoria:device:#{device.slug}:events"
    end

    def require_active_device!(character)
      device = PresenceManager.active_device(character)
      raise NoActiveDevice, "character #{character.id} (#{character.name}) has no active device" unless device
      device
    end

    def resolve_device(ref)
      return ref if ref.is_a?(Device)
      Device.find_by(slug: ref.to_s)
    end
  end
end
