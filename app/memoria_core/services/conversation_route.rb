require "json"

# 会話がどの経路（Discord、デバイスの API など）の、どの場所から来ているか。値オブジェクト（副作用なし）。
#
# 常駐の claude は、会話の記録ごとに1本で、経路が変わっても使い続ける。そのため経路は、起動時に固定される
# システムプロンプトやツールではなく、毎ターンの「背景」と、ツール呼び出し時に読むファイルで伝える。
#
# 契約:
# - platform は Symbol か nil（空文字は nil）。channel は前後の空白を除いた String か nil（空は nil）
# - 同じ platform と channel なら同じ値（==）
# - parse(dump(route)) == route（ファイルを介しても変わらない）
# - parse は、壊れた入力・nil に対して、例外ではなく経路なし（platform nil, channel nil）を返す
# - line は、どんな経路でも、必ず1行を返す（nil を返さない）。常駐の claude は前のターンの経路を覚えているので、
#   channel がない経路（デバイスの API など）でも、いまの経路を毎ターン伝えなければならない
class ConversationRoute
  # memoria が知っている経路。ツールの一覧は、これらすべてのツールの和集合として起動時に作る
  PLATFORMS = [ nil, :discord ].freeze

  attr_reader :platform, :channel

  def initialize(platform: nil, channel: nil)
    @platform = platform.to_s.strip.empty? ? nil : platform.to_s.strip.to_sym
    @channel = channel.to_s.strip.empty? ? nil : channel.to_s.strip
    freeze
  end

  def self.dump(route)
    JSON.generate(platform: route.platform&.to_s, channel: route.channel)
  end

  def self.parse(text)
    data = JSON.parse(text.to_s)
    return new unless data.is_a?(Hash)

    new(platform: data["platform"], channel: data["channel"])
  rescue JSON::ParserError
    new
  end

  LABELS = { discord: "Discord" }.freeze
  DEFAULT_LABEL = "デバイスの API".freeze

  # システムが毎ターン添える、経路の1行。channel があればそれ、なければ経路の名前を使う
  def line
    "あなたは現在、#{channel || LABELS.fetch(platform, platform ? platform.to_s : DEFAULT_LABEL)}を通じて会話しています。"
  end

  def ==(other)
    other.is_a?(self.class) && platform == other.platform && channel == other.channel
  end
  alias eql? ==

  def hash
    [ platform, channel ].hash
  end
end
