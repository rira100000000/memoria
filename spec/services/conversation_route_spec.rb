require "rails_helper"

RSpec.describe ConversationRoute do
  it "platform は Symbol か nil に、channel は空白を除いた String か nil にそろえる" do
    route = described_class.new(platform: "discord", channel: "  Discord #general ")

    expect(route.platform).to eq(:discord)
    expect(route.channel).to eq("Discord #general")
    expect(described_class.new(platform: "", channel: " ")).to have_attributes(platform: nil, channel: nil)
  end

  it "同じ platform と channel なら等しく、ハッシュのキーにもできる" do
    a = described_class.new(platform: :discord, channel: "x")
    b = described_class.new(platform: "discord", channel: "x")

    expect(a).to eq(b)
    expect({ a => 1 }[b]).to eq(1)
    expect(a).not_to eq(described_class.new(platform: :discord, channel: "y"))
  end

  it "変更できない" do
    expect(described_class.new).to be_frozen
  end

  describe "#line" do
    it "channel があれば、経路を伝える1行を返す" do
      expect(described_class.new(channel: "Discord #general").line).to eq("あなたは現在、Discord #generalを通じて会話しています。")
    end

    it "channel がなければ、経路の名前で伝える（nil を返さない）" do
      expect(described_class.new(platform: :discord).line).to eq("あなたは現在、Discordを通じて会話しています。")
      expect(described_class.new.line).to eq("あなたは現在、デバイスの APIを通じて会話しています。")
      expect(described_class.new(platform: :reading).line).to eq("あなたは現在、readingを通じて会話しています。")
    end

    it "どんな経路でも空にならず、経路が違えば違う文になる" do
      lines = [ described_class.new, described_class.new(platform: :discord), described_class.new(channel: "x") ].map(&:line)

      expect(lines.map(&:to_s)).to all(match(/を通じて会話しています。\z/))
      expect(lines.uniq.size).to eq(3)
    end
  end

  describe "dump と parse" do
    it "ファイルを介しても変わらない" do
      [ described_class.new, described_class.new(platform: :discord, channel: "a b"), described_class.new(channel: "日本語") ].each do |route|
        expect(described_class.parse(described_class.dump(route))).to eq(route)
      end
    end

    it "壊れた入力や nil は、経路なしにする" do
      expect(described_class.parse("{")).to eq(described_class.new)
      expect(described_class.parse(nil)).to eq(described_class.new)
      expect(described_class.parse("[1]")).to eq(described_class.new)
    end
  end

  it "知っている経路は、API（nil）と Discord" do
    expect(described_class::PLATFORMS).to eq([ nil, :discord ])
  end
end
