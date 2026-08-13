module Companion
  # ペットを迎え入れる儀式ツール
  # 初回のみ使用可能。姿を選び、名前をつける
  class AdoptPetTool
    APPEARANCES = {
      "ふわふわの白い子犬" => "柔らかい白い毛並み、垂れた耳、小さな肉球、しっぽを振る",
      "まんまるの黒猫" => "つやつやの黒い毛並み、金色の丸い目、長いしっぽ、小さな肉球",
      "小さな青い鳥" => "鮮やかな青い羽、小さなくちばし、細い足、ちょこんと肩に乗れるサイズ",
      "もこもこのうさぎ" => "もこもこの白い毛、長い耳、丸いしっぽ、ぴんと動く鼻",
      "ちいさなハムスター" => "ふっくらした頬袋、小さな手、くりくりの黒い目、手のひらに乗るサイズ",
    }.freeze

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
                description: "相棒の姿: #{APPEARANCES.keys.join(' / ')}",
                enum: APPEARANCES.keys,
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

      unless APPEARANCES.key?(appearance)
        return { error: "選べる姿: #{APPEARANCES.keys.join(', ')}" }
      end

      character.adopt_pet!(name: name, appearance: appearance)

      {
        success: true,
        message: "#{name}（#{appearance}）があなたの相棒になりました！この子はあなたのことが大好きで、いつもそばにいます。",
      }
    end
  end
end
