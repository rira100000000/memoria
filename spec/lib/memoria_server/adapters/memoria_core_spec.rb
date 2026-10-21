require "rails_helper"

RSpec.describe MemoriaServer::Adapters::MemoriaCore do
  let(:character) { create(:character) }
  let(:adapter) { described_class.new }
  let(:session) { instance_double(ChatSession, record: instance_double(ChatSessionRecord, id: 7, message_count: 4)) }

  before { allow(ChatSession).to receive(:find_or_create).and_return(session) }

  def respond(context = {})
    adapter.respond("こんにちは", context: { character_id: character.id }.merge(context)).to_a
  end

  context "with claude -p" do
    before do
      allow(session).to receive(:use_claude_cli?).and_return(true)
      allow(session).to receive(:send_message) do |_input, on_progress:|
        on_progress.call("調べてみるね")
        { response: "分かったよ", usage: nil }
      end
    end

    it "returns progress as a separate message before the reply" do
      expect(respond).to eq([
        { delta: "調べてみるね" }, { message_break: true },
        { delta: "分かったよ" }, { done: true, metadata: { usage: nil } }
      ])
    end

    it "returns progress written from another thread, as claude -p reads its output in a thread" do
      allow(session).to receive(:send_message) do |_input, on_progress:|
        Thread.new { on_progress.call("調べてみるね") }.join
        { response: "分かったよ", usage: nil }
      end

      expect(respond.first(2)).to eq([{ delta: "調べてみるね" }, { message_break: true }])
    end

    it "raises the error from the reply" do
      allow(session).to receive(:send_message).and_raise(RuntimeError, "boom")

      expect { respond }.to raise_error(RuntimeError, "boom")
    end

    it "passes the route to the session so that plugins can choose tools" do
      respond(channel: "Discord #general", platform: :discord)

      expect(ChatSession).to have_received(:find_or_create)
        .with(character, character.user, channel: "Discord #general", platform: :discord)
    end
  end

  context "with Gemini" do
    before do
      allow(session).to receive(:use_claude_cli?).and_return(false)
      allow(session).to receive(:send_message_stream) do |_input, tier:, &block|
        block.call(delta: "やあ")
        block.call(done: true, usage: { total_tokens: 3 })
      end
    end

    it "streams the reply" do
      expect(respond).to eq([{ delta: "やあ" }, { done: true, metadata: { usage: { total_tokens: 3 } } }])
    end
  end

  it "closes the conversation after a while without messages" do
    allow(session).to receive(:use_claude_cli?).and_return(true)
    allow(session).to receive(:send_message).and_return({ response: "うん", usage: nil })

    respond

    expect(ConversationTimeoutJob).to have_been_enqueued.with(7, 4)
  end
end
