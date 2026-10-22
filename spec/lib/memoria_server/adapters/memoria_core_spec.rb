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

  describe "#recall" do
    let(:retriever) { instance_double(MemoriaCore::ContextRetriever) }

    before do
      allow(MemoriaCore::EmbeddingStore).to receive(:new).and_return(instance_double(MemoriaCore::EmbeddingStore, initialize!: nil))
      allow(MemoriaCore::ContextRetriever).to receive(:new).and_return(retriever)
    end

    it "returns the memories related to the query" do
      allow(retriever).to receive(:retrieve).with("雨の匂い")
        .and_return({ retrieved_items: [{}], llm_context_prompt: "雨の日の記憶" })

      expect(adapter.recall(character_id: character.id, query: "雨の匂い")).to eq("雨の日の記憶")
    end

    it "returns nil when nothing is found" do
      allow(retriever).to receive(:retrieve).and_return({ retrieved_items: [], llm_context_prompt: "見つかりませんでした" })

      expect(adapter.recall(character_id: character.id, query: "なにか")).to be_nil
    end
  end

  it "memorizes through MemorizeService" do
    allow(MemorizeService).to receive(:run).and_return({ full_log_path: "FullLog/x.md" })

    expect(adapter.memorize(character_id: character.id, text: "読んだ", source: "reading", metadata: { work_title: "こころ" })).to be true
    expect(MemorizeService).to have_received(:run)
      .with(character, text: "読んだ", source: "reading", metadata: { work_title: "こころ" })
  end

  it "closes the conversation after a while without messages" do
    allow(session).to receive(:use_claude_cli?).and_return(true)
    allow(session).to receive(:send_message).and_return({ response: "うん", usage: nil })

    respond

    expect(ConversationTimeoutJob).to have_been_enqueued.with(7, 4)
  end
end
