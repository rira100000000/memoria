require "rails_helper"

RSpec.describe MemoriaServer::DiscordProtocol do
  def parse_all(*chunks)
    parser = described_class::Parser.new
    chunks.flat_map { |chunk| parser.feed(chunk) }
  end

  describe ".encode" do
    it "1イベントを、1つの文字列で返す" do
      text = described_class.encode("message", text: "やあ", last: true)

      expect(text).to eq("event: message\ndata: {\"text\":\"やあ\",\"last\":true}\n\n")
    end

    it "Parser で、元のイベントに戻る" do
      events = parse_all(described_class.encode("message", text: "a\nb", last: false), described_class.encode("done"))

      expect(events).to eq([ { event: "message", data: { "text" => "a\nb", "last" => false } }, { event: "done", data: {} } ])
    end
  end

  describe "Parser" do
    let(:stream) { described_class.encode("accepted", character: "ハル") + described_class::PING + described_class.encode("done") }

    it "チャンクの区切りがどこにあっても、同じイベントの列を返す" do
      whole = parse_all(stream)

      (1...stream.length).each do |cut|
        expect(parse_all(stream[0...cut], stream[cut..])).to eq(whole)
      end
    end

    it "コメント行（ping）を捨てる" do
      expect(parse_all(described_class::PING)).to eq([])
    end

    it "壊れた data のイベントは捨て、続きを読める" do
      events = parse_all("event: x\ndata: {\n\n", described_class.encode("done"))

      expect(events.map { |e| e[:event] }).to eq([ "done" ])
    end

    it "イベントの終わり（空行）がないものは、まだ返さない" do
      expect(parse_all("event: done\ndata: {}\n")).to eq([])
    end

    it "CRLF の区切りも読める" do
      expect(parse_all("event: done\r\ndata: {}\r\n\r\n")).to eq([ { event: "done", data: {} } ])
    end
  end

  describe ".split_message" do
    it "上限以下はそのまま返す" do
      expect(described_class.split_message("あ" * 2000)).to eq([ "あ" * 2000 ])
    end

    it "上限を超えたら、結合すると元に戻り、各片が上限以下になるよう分ける" do
      text = "あ\n" * 2500
      parts = described_class.split_message(text)

      expect(parts.join).to eq(text)
      expect(parts.map(&:length).max).to be <= 2000
      expect(parts.length).to eq(3)
    end
  end

  describe ".allowed_user?" do
    it "一覧が空なら全員を許可する" do
      expect(described_class.allowed_user?([], "1")).to be(true)
      expect(described_class.allowed_user?(nil, "1")).to be(true)
    end

    it "一覧があれば、含まれる人だけを許可する（数でも文字列でも）" do
      expect(described_class.allowed_user?(%w[1 2], 2)).to be(true)
      expect(described_class.allowed_user?(%w[1 2], "3")).to be(false)
      expect(described_class.allowed_user?(%w[1 2], nil)).to be(false)
    end
  end

  describe ".parse_ids" do
    it "カンマ区切りを、空要素を捨てて配列にする" do
      expect(described_class.parse_ids(" 1, 2 ,,3")).to eq(%w[1 2 3])
      expect(described_class.parse_ids(nil)).to eq([])
    end
  end

  describe ".error_for" do
    it "順番待ちの時間切れは busy にする" do
      expect(described_class.error_for(MemoriaServer::Busy.new("x"))).to include(kind: "busy")
    end

    it "それ以外は failed にして、メッセージは200文字までにする" do
      error = described_class.error_for(RuntimeError.new("x" * 500))

      expect(error[:kind]).to eq("failed")
      expect(error[:message].length).to be <= 215
    end
  end
end
