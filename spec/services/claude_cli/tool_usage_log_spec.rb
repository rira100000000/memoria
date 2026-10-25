require "rails_helper"

RSpec.describe ClaudeCli::ToolUsageLog do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "tool_calls", "usage.jsonl") }

  after { FileUtils.remove_entry(dir) }

  def entries
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  it "writes one line per call with the time in JST, creating the directory" do
    log = described_class.new(path: path, scene: "chat", trigger: "user_message", platform: "discord", character_id: 1)

    travel_to(Time.utc(2026, 10, 25, 16, 30)) do
      expect(log.measure("search_memory") { { results: "記憶" } }).to eq(results: "記憶")
    end

    entry = entries.first
    expect(entry).to include("date" => "2026-10-26", "at" => "2026-10-26T01:30:00+09:00", "tool" => "search_memory",
      "scene" => "chat", "trigger" => "user_message", "platform" => "discord", "character_id" => 1, "ok" => true)
    expect(entry["ms"]).to be >= 0
    expect(entry).not_to have_key("wakeup_id")
  end

  it "counts results with an error as failures" do
    log = described_class.new(path: path, scene: "chat")
    log.measure("vault_read") { { error: "not found" } }

    expect(entries.first["ok"]).to be(false)
  end

  it "labels the thinking loop and wakeups" do
    described_class.new(path: path, scene: "thinking", trigger: "thinking_loop").measure("a") { {} }
    described_class.new(path: path, scene: "thinking", trigger: "thinking_loop",
      context: { "wakeup_id" => 9, "purpose" => "作業の結果を伝える: " + "あ" * 100 }).measure("b") { {} }

    first, second = entries
    expect(first["scene"]).to eq("thinking_loop")
    expect(second).to include("scene" => "wakeup", "wakeup_id" => 9)
    expect(second["purpose"].length).to eq(described_class::PURPOSE_CHARS)
  end

  it "warns instead of raising when it cannot write" do
    File.write(File.join(dir, "tool_calls"), "not a directory")
    allow(Rails.logger).to receive(:warn)

    result = described_class.new(path: path, scene: "chat").measure("a") { { ok: 1 } }

    expect(result).to eq(ok: 1)
    expect(Rails.logger).to have_received(:warn).with(a_string_including("Could not record a"))
  end
end
