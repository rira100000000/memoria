module MemoriaServer
  module Capabilities
    # 感情ラベル：aituber-kit 等の VRoid 系クライアントの標準表情と互換。
    EMOTION_VALUES = %w[neutral happy sad angry surprised relaxed].freeze

    EMOTION = MemoriaServer::Capability.new(
      name: :emotion,
      value_format: %("happy" / "sad" / "angry" / "surprised" / "neutral" / "relaxed" のいずれか),
      value_extractor: ->(obj) {
        val = obj["emotion"] || obj[:emotion]
        EMOTION_VALUES.include?(val.to_s) ? val.to_s : nil
      },
    )

    MemoriaServer::Capability.register(EMOTION)
  end
end
