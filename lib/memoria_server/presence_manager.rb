module MemoriaServer
  # キャラクターの presence（どのデバイスにいるか）を管理する。
  # transfer は MS の最も独自性の高い操作で、原子的に：
  #   1) 旧デバイスの presence を解除
  #   2) 新デバイスを active にする
  #   3) Transfer ログを記録
  #   4) 旧デバイスに departed、新デバイスに arrived を push
  # を行う。
  module PresenceManager
    module_function

    # @param character [Character]
    # @return [Presence]
    def for(character)
      Presence.find_or_create_by!(character: character)
    end

    # @param character [Character]
    # @param to_device [Device]
    # @param reason [String] "user_requested" / "displaced_by_call" / "ai_initiated:bored" / ...
    # @return [Hash] { from_device:, to_device:, transferred: bool }
    def transfer!(character:, to_device:, reason: "user_requested")
      raise ArgumentError, "to_device required" unless to_device

      result = nil
      ActiveRecord::Base.transaction do
        presence = self.for(character).lock!
        from_device = presence.active_device

        # 同一デバイスへの transfer は no-op
        if from_device&.id == to_device.id
          result = { from_device: from_device, to_device: to_device, transferred: false }
          next
        end

        presence.assign_to!(to_device)
        Transfer.record!(
          character: character,
          from_device: from_device,
          to_device: to_device,
          reason: reason,
        )
        result = { from_device: from_device, to_device: to_device, transferred: true }
      end

      if result[:transferred]
        notify_transfer(character: character, from_device: result[:from_device], to_device: result[:to_device], reason: reason)
      end
      result
    end

    # 現在の active device を返す（presence レコードがなければ nil）。
    def active_device(character)
      Presence.find_by(character_id: character.id)&.active_device
    end

    # キャラクターをどのデバイスからも解放する（誰のもとにもいない状態）。
    # Transfer ログは記録しない（to_device が NOT NULL 制約のため）。
    # 「行先のない離脱」が頻発する設計になったら transfers テーブルを見直す。
    def release!(character:, reason: "released")
      from_device = nil
      ActiveRecord::Base.transaction do
        presence = self.for(character).lock!
        from_device = presence.active_device
        next unless from_device
        presence.release!
      end

      if from_device
        Push.publish_to_device(from_device, "presence.departed", {
          character_id: character.id,
          reason: reason,
        })
      end
    end

    def notify_transfer(character:, from_device:, to_device:, reason:)
      if from_device
        Push.publish_to_device(from_device, "presence.departed", {
          character_id: character.id,
          to_device_slug: to_device.slug,
          reason: reason,
        })
      end
      Push.publish_to_device(to_device, "presence.arrived", {
        character_id: character.id,
        from_device_slug: from_device&.slug,
        reason: reason,
      })
    end
  end
end
