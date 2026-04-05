module Companion
  # ペットを迎え入れる儀式ツール
  # 初回のみ使用可能。姿を選び、名前をつける
  class AdoptPetTool
    APPEARANCES = [
      "ふわふわの白い子犬",
      "まんまるの黒猫",
      "小さな青い鳥",
      "もこもこのうさぎ",
      "ちいさなハムスター",
    ].freeze

    def self.definition
      {
        functionDeclarations: [{
          name: "adopt_pet",
          description: "あなたの内面世界に小さな相棒を迎え入れる。姿を選び、名前をつけてあげてください。この子はあなただけの唯一無二のパートナーになります。",
          parameters: {
            type: "OBJECT",
            properties: {
              appearance: {
                type: "STRING",
                description: "相棒の姿: #{APPEARANCES.join(' / ')}",
                enum: APPEARANCES,
              },
              name: {
                type: "STRING",
                description: "相棒につける名前（自由につけてください）",
              },
            },
            required: ["appearance", "name"],
          },
        }],
      }
    end

    def self.execute(character:, name:, appearance:)
      return { error: "既に相棒がいます（#{character.pet_name}）" } if character.has_pet?

      unless APPEARANCES.include?(appearance)
        return { error: "選べる姿: #{APPEARANCES.join(', ')}" }
      end

      character.adopt_pet!(name: name, appearance: appearance)

      {
        success: true,
        message: "#{name}（#{appearance}）があなたの相棒になりました！この子はあなたのことが大好きで、いつもそばにいます。",
      }
    end
  end
end
