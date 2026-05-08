require "rails_helper"

RSpec.describe MemoriaServer::StreamingMetadataExtractor do
  let(:capabilities) { [MemoriaServer::Capabilities::EMOTION] }
  let(:extractor) { described_class.new(capabilities: capabilities) }

  def collect(text)
    events = []
    extractor.feed(text) { |k, p| events << [k, p] }
    events
  end

  def finalize_collect
    events = []
    extractor.finalize { |k, p| events << [k, p] }
    events
  end

  describe "#feed" do
    it "emits text and metadata in order for tag at start" do
      events = collect(%(<x_memoria>{"emotion":"happy"}</x_memoria>こんにちは))
      expect(events).to eq([
        [:metadata, { emotion: "happy" }],
        [:text, "こんにちは"]
      ])
    end

    it "emits text-then-metadata-then-text for tag in middle" do
      events = collect(%(やぁ<x_memoria>{"emotion":"sad"}</x_memoria>元気ない))
      expect(events).to eq([
        [:text, "やぁ"],
        [:metadata, { emotion: "sad" }],
        [:text, "元気ない"]
      ])
    end

    it "emits multiple metadata changes inline" do
      events = collect(%(<x_memoria>{"emotion":"happy"}</x_memoria>こんにちは<x_memoria>{"emotion":"surprised"}</x_memoria>えっ))
      expect(events).to eq([
        [:metadata, { emotion: "happy" }],
        [:text, "こんにちは"],
        [:metadata, { emotion: "surprised" }],
        [:text, "えっ"]
      ])
    end

    it "holds back partial open tag across feed boundaries" do
      events = []
      extractor.feed("やぁ<x_me") { |k, p| events << [k, p] }
      expect(events).to eq([[:text, "やぁ"]])

      events = []
      extractor.feed(%(moria>{"emotion":"happy"}</x_memoria>はい)) { |k, p| events << [k, p] }
      expect(events).to eq([
        [:metadata, { emotion: "happy" }],
        [:text, "はい"]
      ])
    end

    it "ignores plain text without tags" do
      events = collect("ただのテキスト")
      expect(events).to eq([[:text, "ただのテキスト"]])
    end

    it "treats malformed JSON inside tag as empty metadata (silent)" do
      events = collect(%(<x_memoria>not json</x_memoria>テキスト))
      # メタデータは empty なので yield されない、テキストは続く
      expect(events).to eq([[:text, "テキスト"]])
    end

    it "ignores unknown emotion values" do
      events = collect(%(<x_memoria>{"emotion":"ecstatic"}</x_memoria>テキスト))
      expect(events).to eq([[:text, "テキスト"]])
    end

    it "handles content split character by character" do
      events = []
      %(<x_memoria>{"emotion":"happy"}</x_memoria>hi).each_char do |c|
        extractor.feed(c) { |k, p| events << [k, p] }
      end
      extractor.finalize { |k, p| events << [k, p] }
      expect(events).to include([:metadata, { emotion: "happy" }])
      texts = events.select { |k, _| k == :text }.map { |_, t| t }.join
      expect(texts).to eq("hi")
    end
  end

  describe "#finalize" do
    it "discards unclosed metadata buffer" do
      extractor.feed(%(text<x_memoria>{"emotion":"happy")) { |_, _| }
      events = finalize_collect
      expect(events).to eq([])  # 開きタグ後にテキストもメタデータも出ない
    end

    it "flushes partial-tag holdback as text" do
      events = []
      extractor.feed("text<x_me") { |k, p| events << [k, p] }
      # "text" がインライン emit される、"<x_me" は holdback
      expect(events).to eq([[:text, "text"]])
      events = finalize_collect
      expect(events).to eq([[:text, "<x_me"]])
    end
  end
end
