require "rails_helper"

RSpec.describe PromptBuilder do
  let(:vault_root) { Dir.mktmpdir }
  let(:character) { create(:character) }

  around do |example|
    original = ENV["VAULT_ROOT"]
    ENV["VAULT_ROOT"] = vault_root
    example.run
  ensure
    ENV["VAULT_ROOT"] = original
    FileUtils.remove_entry(vault_root)
  end

  def build
    described_class.new(character).build(context: { retrieved_context: "" })
  end

  def write_vault_file(name, text)
    FileUtils.mkdir_p(character.vault_path)
    File.write(File.join(character.vault_path, name), text)
  end

  it "includes what the character wrote about itself, with where to rewrite it" do
    write_vault_file("self.md", "私は好奇心で動いている。\n")

    prompt = build

    expect(prompt).to include("## あなたが自分について書いたもの", "私は好奇心で動いている。")
    expect(prompt).to include(File.join(character.vault_path, "self.md"))
  end

  it "puts the self description before the custom instructions" do
    write_vault_file("self.md", "自己認識")
    write_vault_file("custom_instructions.md", "追加の指示")

    prompt = build

    expect(prompt.index("自己認識")).to be < prompt.index("追加の指示")
  end

  it "leaves the section out when the file is missing or empty" do
    expect(build).not_to include("あなたが自分について書いたもの")

    write_vault_file("self.md", "  \n")
    expect(build).not_to include("あなたが自分について書いたもの")
  end

  describe "separating what changes every turn" do
    let(:context) do
      {
        retrieved_context: "昨日はカレーを作った",
        narrative_summary: "朝から設計の話をしている",
        behavior_principles: "嘘をつかない",
        prospective_memory: "- 牛乳を買う",
        upcoming_schedules: "10:00 散歩"
      }
    end
    let(:builder) { described_class.new(character) }
    let(:changing) { [ "Current time is", "朝から設計の話をしている", "昨日はカレーを作った", "牛乳を買う", "10:00 散歩" ] }

    it "keeps the whole prompt as it was, with the changing sections in their usual place" do
      prompt = builder.build(context: context)

      expect(prompt).to include(*changing, "嘘をつかない")
      expect(prompt.index("Current time is")).to be < prompt.index("嘘をつかない")
      expect(prompt.index("嘘をつかない")).to be < prompt.index("朝から設計の話をしている")
      expect(prompt.index("昨日はカレーを作った")).to be < prompt.index("牛乳を買う")
      expect(prompt.index("牛乳を買う")).to be < prompt.index("10:00 散歩")
      expect(prompt.index("10:00 散歩")).to be < prompt.index(PromptBuilder::MEMORIA_INSTRUCTION)
    end

    it "leaves the changing sections out with dynamic: false, and keeps the rest" do
      prompt = builder.build(context: context, dynamic: false)

      changing.each { |text| expect(prompt).not_to include(text) }
      expect(prompt).to include("嘘をつかない", PromptBuilder::MEMORIA_INSTRUCTION)
    end

    it "builds exactly the left-out sections with build_dynamic" do
      dynamic = builder.build_dynamic(context: context)

      expect(dynamic).to include(*changing)
      expect(dynamic).not_to include("嘘をつかない")
      expect(builder.build(context: context)).to include(dynamic.sub(/\ACurrent time is [^\n]*\n\n/, "").split("\n\n").first)
    end

    it "can leave out the prospective memory and the schedules when they have not changed" do
      dynamic = builder.build_dynamic(context: context, prospective: false, schedules: false)

      expect(dynamic).to include("昨日はカレーを作った", "朝から設計の話をしている")
      expect(dynamic).not_to include("牛乳を買う", "10:00 散歩")
    end
  end
end
