module MemoriaServer
  module Capabilities
    # ダンス・身振り用のモーションプリセット。
    # Stack-chan のような物理デバイスが具体的な servo シーケンスにマッピングする想定。
    #
    # 「気分で踊る」用途のため、emotion と独立して指示できるようにする：
    # 例えば emotion=happy でも motion=idle（動かない）にも、motion=excited_bounce にもできる。
    MOTION_VALUES = %w[
      idle
      happy_wiggle
      sad_droop
      surprised_jump
      relaxed_sway
      thinking_tilt
      excited_bounce
      listening_nod
    ].freeze

    MOTION_PROMPT = <<~TXT.freeze
      motion はキャラクターの身体動作（首振り・身振り）です。emotion と独立して指示できます：
      内心は happy でも、発話内容によっては motion=idle（動かない）が自然なこともあります。

      使い分けの目安：
      - idle: 通常の会話、特別なきっかけがない発話
      - happy_wiggle: 嬉しい話題、褒められた、楽しい予定
      - sad_droop: 悲しい話、申し訳ない、しょんぼり
      - surprised_jump: 強い驚き、想定外の出来事
      - relaxed_sway: 落ち着いた話、雑談、リラックス
      - thinking_tilt: 考え中、迷い、思案
      - excited_bounce: テンションが高い、ノリノリ、イベント開始
      - listening_nod: 相手の話をじっくり聞いている、相槌

      motion は1〜2文に1回程度、無理に頻繁に変えない。動きが不要なら idle を出してください。
    TXT

    MOTION = MemoriaServer::Capability.new(
      name: :motion,
      value_format: %("idle" / "happy_wiggle" / "sad_droop" / "surprised_jump" / "relaxed_sway" / "thinking_tilt" / "excited_bounce" / "listening_nod" のいずれか),
      value_extractor: ->(obj) {
        val = obj["motion"] || obj[:motion]
        MOTION_VALUES.include?(val.to_s) ? val.to_s : nil
      },
      prompt_segment: MOTION_PROMPT,
    )

    MemoriaServer::Capability.register(MOTION)
  end
end
