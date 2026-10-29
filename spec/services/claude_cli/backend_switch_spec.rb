require "rails_helper"

RSpec.describe ClaudeCli, "choosing claude or codex" do
  around do |example|
    keys = %w[LLM_CLI_BACKEND CLAUDE_CLI_BACKEND CODEX_CLI_MODEL CODEX_CLI_DEEP_MODEL CODEX_CLI_LIGHT_MODEL CODEX_CLI_CHAT_MODEL CLAUDE_CLI_MODEL CLAUDE_CLI_CHAT_MODEL CLAUDE_CLI_DEEP_MODEL MEMORIA_AGENT_BACKEND]
    original = ENV.to_h.slice(*keys)
    example.run
  ensure
    keys.each { |k| ENV[k] = original[k] }
  end

  it "uses claude when nothing is set" do
    ENV.delete("LLM_CLI_BACKEND")

    expect(described_class.backend).to eq("claude")
    expect(described_class.model).to eq("sonnet")
    expect(described_class.model(deep: true)).to eq("opus")
    expect(described_class.light_model).to eq("haiku")
    expect(ClaudeCli::Runner.new.backend).to be_a(ClaudeCli::Backends::Claude)
    expect(described_class.failure_notice(ClaudeCli::Error.new("x"), what: "返答")).to include("claude -p が使えなかった")
  end

  it "uses claude when set to claude explicitly" do
    ENV["LLM_CLI_BACKEND"] = "claude"
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"

    expect(described_class.backend).to eq("claude")
    expect(described_class.codex?).to be(false)
    expect(ClaudeCli::Runner.new.backend).to be_a(ClaudeCli::Backends::Claude)
  end

  it "accepts the name regardless of case and surrounding spaces" do
    ENV["LLM_CLI_BACKEND"] = " Codex "

    expect(described_class.backend).to eq("codex")
  end

  it "does not read the former variable name CLAUDE_CLI_BACKEND" do
    ENV.delete("LLM_CLI_BACKEND")
    ENV["CLAUDE_CLI_BACKEND"] = "codex"

    expect(described_class.backend).to eq("claude")
  end

  it "falls back to claude for an unknown name" do
    ENV["LLM_CLI_BACKEND"] = "gemini"

    expect(described_class.backend).to eq("claude")
  end

  it "uses codex with its own models when set" do
    ENV["LLM_CLI_BACKEND"] = "codex"
    ENV["CODEX_CLI_MODEL"] = "gpt-x"
    ENV.delete("CODEX_CLI_DEEP_MODEL")
    ENV.delete("CODEX_CLI_LIGHT_MODEL")
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"

    expect(described_class.backend).to eq("codex")
    expect(described_class.model).to eq("gpt-x")
    expect(described_class.model(deep: true)).to eq(ClaudeCli::CODEX_DEFAULT_DEEP_MODEL)
    expect(described_class.light_model).to eq(ClaudeCli::CODEX_DEFAULT_LIGHT_MODEL)
    expect(described_class.deep_model_available?).to be(true)
    expect(ClaudeCli::Runner.new.backend).to be_a(ClaudeCli::Backends::Codex)
    expect(described_class.failure_notice(ClaudeCli::Error.new("x"), what: "返答")).to include("codex exec が使えなかった")
  end

  it "uses the chat model only for conversations" do
    ENV.delete("LLM_CLI_BACKEND")
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"
    ENV["CLAUDE_CLI_MODEL"] = "sonnet"
    ENV["CLAUDE_CLI_DEEP_MODEL"] = "opus"
    ENV["CLAUDE_CLI_CHAT_MODEL"] = "haiku"

    expect(described_class.model).to eq("sonnet")
    expect(described_class.chat_model).to eq("haiku")
    expect(described_class.chat_model(deep: true)).to eq("opus")
    expect(described_class.deep_model_available?).to be(true)
  end

  it "falls back to the usual model when no chat model is set" do
    ENV.delete("LLM_CLI_BACKEND")
    ENV["CLAUDE_CLI_MODEL"] = "sonnet"
    ENV["CLAUDE_CLI_CHAT_MODEL"] = ""

    expect(described_class.chat_model).to eq("sonnet")
  end

  it "offers no deep model when the chat model is already the deep one" do
    ENV.delete("LLM_CLI_BACKEND")
    ENV["MEMORIA_AGENT_BACKEND"] = "claude_cli"
    ENV["CLAUDE_CLI_MODEL"] = "sonnet"
    ENV["CLAUDE_CLI_DEEP_MODEL"] = "opus"
    ENV["CLAUDE_CLI_CHAT_MODEL"] = "opus"

    expect(described_class.deep_model_available?).to be(false)
  end

  it "reads the codex chat model when running on codex" do
    ENV["LLM_CLI_BACKEND"] = "codex"
    ENV["CODEX_CLI_MODEL"] = "gpt-x"
    ENV["CODEX_CLI_CHAT_MODEL"] = "gpt-6-luna:medium"

    expect(described_class.chat_model).to eq("gpt-6-luna:medium")
    expect(described_class.model).to eq("gpt-x")
  end

  it "rejects an unknown backend given to the runner" do
    expect { ClaudeCli::Runner.new(backend: "gemini") }.to raise_error(ArgumentError)
  end
end
