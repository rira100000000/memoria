require "rails_helper"

RSpec.describe MemorizeService do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character) }
  let(:reflection) { instance_double(ReflectionService) }

  around do |example|
    original = ENV["VAULT_ROOT"]
    ENV["VAULT_ROOT"] = vault_root
    example.run
  ensure
    ENV["VAULT_ROOT"] = original
    FileUtils.remove_entry(vault_root)
  end

  before do
    MemoriaCore::Core.new(character.vault_path).vault.ensure_structure!
    allow(ReflectionService).to receive(:new).and_return(reflection)
    allow(reflection).to receive(:generate).and_return(nil)
  end

  def full_log(result)
    MemoriaCore::Core.new(character.vault_path).vault.read(result[:full_log_path])
  end

  it "keeps the text in the full log with its source and metadata, and reflects on it" do
    result = described_class.run(character, text: "ルル: ぴよ", source: "autonomous", metadata: { participants: ["self"] },
      llm_client: instance_double(LlmClient))

    expect(full_log(result)).to include("ルル: ぴよ").and include("source: autonomous").and include("- self")
    expect(reflection).to have_received(:generate).with(hash_including(conversation_text: "ルル: ぴよ", context_type: nil))
  end

  it "reflects on a reading as a reading" do
    described_class.run(character, text: "【原文】…", source: "reading", metadata: { work_title: "こころ" },
      llm_client: instance_double(LlmClient))

    expect(reflection).to have_received(:generate).with(hash_including(context_type: :reading))
  end

  it "marks the summary note with the source and updates the tags" do
    core = MemoriaCore::Core.new(character.vault_path)
    core.vault.write("SummaryNote/SN-test.md", MemoriaCore::Frontmatter.build({ "title" => "t" }, "本文"))
    allow(reflection).to receive(:generate).and_return({ file_path: "SummaryNote/SN-test.md" })

    result = described_class.run(character, text: "読んだ", source: "reading", llm_client: instance_double(LlmClient))

    expect(result[:summary_note_path]).to eq("SummaryNote/SN-test.md")
    expect(core.vault.read("SummaryNote/SN-test.md")).to include("source: reading")
    expect(TagProfilingJob).to have_been_enqueued.with(character.id, "SummaryNote/SN-test.md")
  end

  it "does nothing with empty text" do
    expect(described_class.run(character, text: " ", source: "reading")).to be_nil
    expect(reflection).not_to have_received(:generate)
  end
end
