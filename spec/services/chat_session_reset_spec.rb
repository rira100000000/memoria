require "rails_helper"

# reset! の契約:
# - 返答と同じ順番待ち（TurnLock）の中で行う（閉じる途中に新しい返答が始まらない）
# - expected_message_count を渡したとき、ロックを取ったあとの発言数が違えば、閉じずに nil を返す
RSpec.describe ChatSession, "#reset!" do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character, name: "アオイ") }
  let(:record) do
    create(:chat_session_record, character: character,
      messages: [ { "role" => "user", "content" => "こんにちは" }, { "role" => "model", "content" => "やあ" } ])
  end
  let(:session) { described_class.new(character, record: record, llm_client: instance_double(LlmClient), turn_wait: 0.2) }

  around do |example|
    original = ENV["VAULT_ROOT"]
    ENV["VAULT_ROOT"] = vault_root
    example.run
  ensure
    ENV["VAULT_ROOT"] = original
  end

  before do
    allow(ReflectionService).to receive(:new).and_return(instance_double(ReflectionService, generate: nil))
  end

  it "発言数が期待と同じなら、閉じる" do
    session.reset!(expected_message_count: 2)

    expect(record.reload.status).to eq("closed")
  end

  it "発言数が期待と違えば（待っている間に新しい発言があった）、閉じずに nil を返す" do
    expect(session.reset!(expected_message_count: 1)).to be_nil
    expect(record.reload.status).to eq("active")
  end

  it "ロックを取ったあとの記録で数える（取る前に別のプロセスが足した発言も見る）" do
    allow(TurnLock).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      lock = original.call(*args, **kwargs)
      allow(lock).to receive(:synchronize).and_wrap_original do |sync, &block|
        sync.call do
          ChatSessionRecord.find(record.id).append_message("user", "あとから来た発言")
          block.call
        end
      end
      lock
    end

    expect(session.reset!(expected_message_count: 2)).to be_nil
    expect(record.reload.status).to eq("active")
  end

  it "ほかのプロセスが返答中なら、待っても取れなければ TurnBusy を上げ、閉じない" do
    held = File.open(File.join(TurnLock.default_directory.tap { |d| FileUtils.mkdir_p(d) }, TurnLock.file_name(character.id)), File::RDWR | File::CREAT)
    held.flock(File::LOCK_EX)

    expect { session.reset!(expected_message_count: 2) }.to raise_error(ChatSession::TurnBusy)
    expect(record.reload.status).to eq("active")
  ensure
    held&.close
  end

  it "ConversationTimeoutJob は、締めるときに期待する発言数を渡す" do
    session_double = instance_double(ChatSession, reset!: nil)
    allow(ChatSession).to receive(:new).and_return(session_double)

    ConversationTimeoutJob.new.perform(record.id, 2)

    expect(session_double).to have_received(:reset!).with(expected_message_count: 2)
  end
end
