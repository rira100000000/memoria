require "rails_helper"

RSpec.describe MemoriaServer::DiscordReplyStream do
  let(:character) { instance_double(Character, name: "ハル") }
  let(:writes) { [] }
  let(:writer) { Class.new { def initialize(sink) = @sink = sink; def write(s) = @sink << s }.new(writes) }

  def events
    parser = MemoriaServer::DiscordProtocol::Parser.new
    parser.feed(writes.reject { |w| w == MemoriaServer::DiscordProtocol::PING }.join)
  end

  def relay_yielding(*messages)
    Class.new do
      define_singleton_method(:reply) do |_character, _text, **_options, &block|
        messages.each { |text, last| block.call(text, last) }
      end
    end
  end

  def run(relay, **options)
    described_class.new(writer: writer, relay: relay, **options).run(character: character, text: "やあ", channel_name: "Discord #general")
  end

  it "accepted、message（出た順）、done の順に書く" do
    run(relay_yielding([ "調べるね", false ], [ "できたよ", true ]))

    expect(events.map { |e| e[:event] }).to eq(%w[accepted message message done])
    expect(events.select { |e| e[:event] == "message" }.map { |e| e[:data] }).to eq([ { "text" => "調べるね", "last" => false }, { "text" => "できたよ", "last" => true } ])
  end

  it "返答に失敗したら、例外を出さずに、最後に error を1つだけ書く（done は書かない）" do
    relay = Class.new { def self.reply(*, **) = raise(ClaudeCli::Error, "limit") }

    expect { run(relay) }.not_to raise_error
    expect(events.map { |e| e[:event] }).to eq(%w[accepted error])
    expect(events.last[:data]).to include("kind" => "failed")
  end

  it "順番待ちの時間切れは、kind が busy の error にする" do
    relay = Class.new { def self.reply(*, **) = raise(MemoriaServer::Busy, "busy") }

    run(relay)

    expect(events.last).to include(event: "error", data: include("kind" => "busy"))
  end

  it "返答のあいだ、interval ごとに ping を書き、終わったらスレッドを残さない" do
    slow = Class.new { def self.reply(*, **) = sleep(0.35) }
    before = Thread.list.size

    run(slow, interval: 0.1)

    expect(writes.count(MemoriaServer::DiscordProtocol::PING)).to be >= 2
    expect(Thread.list.size).to eq(before)
  end

  it "accepted は、返答（順番待ち）が始まる前に書く" do
    seen = nil
    relay = Class.new do
      define_singleton_method(:reply) { |*, **| seen = writes.dup }
    end
    stream_writes = writes
    relay.define_singleton_method(:writes) { stream_writes }

    run(relay)

    expect(seen.length).to eq(1)
    expect(seen.first).to start_with("event: accepted")
  end

  it "bot が切断しても、返答は最後まで作り、以後の書き込みだけをやめる" do
    broken = Class.new do
      attr_reader :count

      def initialize = @count = 0

      def write(_)
        @count += 1
        raise IOError, "closed stream" if @count > 1
      end
    end.new
    ran_to_end = false
    relay = Class.new do
      define_singleton_method(:reply) do |_c, _t, **_o, &block|
        block.call("1通目", false)
        block.call("2通目", true)
        ran_to_end = true
      end
    end

    described_class.new(writer: broken, relay: relay).run(character: character, text: "やあ", channel_name: "x")

    expect(ran_to_end).to be(true)
    expect(broken.count).to eq(2)
  end

  it "複数のスレッドから書いても、1イベントが混ざらない" do
    chunks = []
    io = Class.new do
      define_method(:write) do |s|
        s.each_char { |c| chunks << c; Thread.pass }
      end
    end.new
    safe = described_class::SafeWriter.new(io)

    threads = 4.times.map { |i| Thread.new { 5.times { safe.write("<#{i}#{i}#{i}>") } } }
    threads.each(&:join)

    joined = chunks.join
    expect(joined.scan(/<(\d)(\d)(\d)>/).all? { |a, b, c| a == b && b == c }).to be(true)
    expect(joined.length).to eq(4 * 5 * 5)
  end
end
