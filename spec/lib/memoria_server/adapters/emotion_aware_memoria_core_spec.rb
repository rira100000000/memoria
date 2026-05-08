require "rails_helper"

RSpec.describe MemoriaServer::Adapters::EmotionAwareMemoriaCore do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:adapter) { described_class.new }

  # ChatSession.find_or_create を mock し、send_message_stream のチャンク列を制御
  let(:mock_session) { instance_double(::ChatSession) }
  let(:llm_chunks) { [] }  # specs override

  before do
    allow(::ChatSession).to receive(:find_or_create) do |_char, _user, **kwargs|
      @captured_extra_instruction = kwargs[:extra_system_instruction]
      mock_session
    end
    allow(mock_session).to receive(:send_message_stream) do |_input, &block|
      llm_chunks.each { |c| block.call(c) }
    end
  end

  context "when wants is empty" do
    it "delegates to MemoriaCore (super)" do
      ctx = { character_id: character.id, x_memoria: { wants: [] } }
      # 親クラスの respond が呼ばれることを確認するため、親側もスタブ
      expect_any_instance_of(MemoriaServer::Adapters::MemoriaCore).to receive(:respond).and_call_original
      # super は実行されるが ChatSession 部分はモック済みなので chunk 流れは制御されている
      let_chunks = [{ delta: "ok" }, { done: true, usage: {} }]
      llm_chunks.replace(let_chunks)
      result = adapter.respond("hello", context: ctx).to_a
      expect(result).to include({ delta: "ok" })
    end

    it "does not inject extra_system_instruction" do
      ctx = { character_id: character.id, x_memoria: {} }
      llm_chunks.replace([{ delta: "ok" }, { done: true, usage: {} }])
      adapter.respond("hi", context: ctx).to_a
      expect(@captured_extra_instruction).to be_nil
    end
  end

  context "when wants includes :emotion" do
    let(:ctx) { { character_id: character.id, x_memoria: { wants: ["emotion"] } } }

    it "injects extra_system_instruction with emotion format" do
      llm_chunks.replace([{ done: true, usage: {} }])
      adapter.respond("hi", context: ctx).to_a
      expect(@captured_extra_instruction).to include("<x_memoria>")
      expect(@captured_extra_instruction).to include("emotion")
    end

    it "extracts metadata and emits separate text + x_memoria chunks" do
      llm_chunks.replace([
        { delta: %(<x_memoria>{"emotion":"happy"}</x_memoria>こん) },
        { delta: "にちは" },
        { done: true, usage: {} }
      ])
      result = adapter.respond("hi", context: ctx).to_a
      expect(result).to eq([
        { x_memoria: { emotion: "happy" } },
        { delta: "こん" },
        { delta: "にちは" },
        { done: true, metadata: { usage: {} } }
      ])
    end

    it "yields multiple x_memoria chunks for inline emotion changes" do
      llm_chunks.replace([
        { delta: %(<x_memoria>{"emotion":"happy"}</x_memoria>あ) },
        { delta: %(<x_memoria>{"emotion":"sad"}</x_memoria>悲しい) },
        { done: true, usage: {} }
      ])
      result = adapter.respond("hi", context: ctx).to_a
      x_memoria_events = result.select { |c| c.key?(:x_memoria) }
      expect(x_memoria_events).to eq([
        { x_memoria: { emotion: "happy" } },
        { x_memoria: { emotion: "sad" } }
      ])
    end

    it "discards malformed json silently and continues text" do
      llm_chunks.replace([
        { delta: %(<x_memoria>not json</x_memoria>テスト) },
        { done: true, usage: {} }
      ])
      result = adapter.respond("hi", context: ctx).to_a
      x_memoria_events = result.select { |c| c.key?(:x_memoria) }
      expect(x_memoria_events).to be_empty
      delta_events = result.select { |c| c.key?(:delta) }
      expect(delta_events).to eq([{ delta: "テスト" }])
    end
  end

  context "with unknown wants" do
    it "ignores unknown capabilities and falls through to plain MemoriaCore behaviour" do
      ctx = { character_id: character.id, x_memoria: { wants: ["unknown_cap"] } }
      llm_chunks.replace([{ delta: "x" }, { done: true, usage: {} }])
      result = adapter.respond("hi", context: ctx).to_a
      expect(result).to include({ delta: "x" })
    end
  end
end
