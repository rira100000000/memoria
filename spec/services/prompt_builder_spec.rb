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
end
