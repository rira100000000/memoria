require "rails_helper"

RSpec.describe MemoriaServer::DiscordRelay do
  let(:character) { create(:character) }
  let(:chunks) { [] }
  let(:adapter) { instance_double(MemoriaServer::Adapter) }

  before do
    allow(MemoriaServer).to receive(:adapter).and_return(adapter)
    allow(adapter).to receive(:respond) { chunks.each }
  end

  def relay
    sent = []
    described_class.reply(character, "やあ", channel_name: "Discord #general") { |text, last| sent << [text, last] }
    sent
  end

  it "passes the message and the route to the adapter" do
    chunks.replace([{ delta: "やあ" }, { done: true }])

    relay

    expect(adapter).to have_received(:respond).with("やあ", context: hash_including(
      character_id: character.id, channel: "Discord #general", platform: :discord, current_input: "やあ"))
  end

  it "joins deltas into one message and marks the reply as the last" do
    chunks.replace([{ delta: "こん" }, { delta: "にちは" }, { done: true, metadata: {} }])

    expect(relay).to eq([["こんにちは", true]])
  end

  it "sends progress before the reply" do
    chunks.replace([{ delta: "調べてみるね" }, { message_break: true }, { delta: "分かったよ" }, { done: true }])

    expect(relay).to eq([["調べてみるね", false], ["分かったよ", true]])
  end

  it "ignores metadata and skips empty messages" do
    chunks.replace([{ x_memoria: { emotion: "happy" } }, { message_break: true }, { delta: "ok" }])

    expect(relay).to eq([["ok", true]])
  end
end
