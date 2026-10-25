require "rails_helper"
require "open3"

RSpec.describe ClaudeCli::ToolUsageSummary do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "usage.jsonl") }
  let(:entries) do
    [
      { date: "2026-10-20", at: "2026-10-20T09:00:00+09:00", tool: "search_memory", scene: "chat", ok: true, ms: 100 },
      { date: "2026-10-22", at: "2026-10-22T10:00:00+09:00", tool: "search_memory", scene: "wakeup", wakeup_id: 3, purpose: "朝の見回り", ok: false, ms: 300 },
      { date: "2026-10-23", at: "2026-10-23T11:00:00+09:00", tool: "vault_read", scene: "thinking_loop", ok: true, ms: 50 },
      { date: "2026-10-25", at: "2026-10-25T12:30:00+09:00", tool: "search_memory", scene: "chat", ok: true, ms: 200 }
    ]
  end

  before { File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n{broken\n") }
  after { FileUtils.remove_entry(dir) }

  it "counts calls, failures, the last use and the scenes per tool" do
    summary = described_class.load(path)

    search, read = summary.rows
    expect(search.to_h.slice(:tool, :count, :failures, :last_at)).to eq(
      tool: "search_memory", count: 3, failures: 1, last_at: "2026-10-25T12:30:00+09:00")
    expect(search.average_ms).to eq(200)
    expect(search.scenes).to eq("chat" => 2, "wakeup" => 1)
    expect(read.tool).to eq("vault_read")
    expect(summary.purposes).to eq([["朝の見回り", 1]])
  end

  it "limits the period by date" do
    summary = described_class.load(path, since: Date.new(2026, 10, 21), until_date: Date.new(2026, 10, 23))

    expect(summary.rows.map { |r| [r.tool, r.count] }).to eq([["search_memory", 1], ["vault_read", 1]])
  end

  it "renders a table" do
    text = described_class.load(path).to_text

    expect(text).to include("期間: 2026-10-20 〜 2026-10-25（4回、2ツール）")
    expect(text).to match(/search_memory\s+3\s+1\s+200\s+2026-10-25 12:30\s+2\s+0\s+1/)
    expect(text).to include("朝の見回り")
  end

  it "says so when there is nothing to count" do
    expect(described_class.load(File.join(dir, "missing.jsonl")).to_text).to start_with("記録がありません")
  end

  it "runs from bin/tool_usage without Rails" do
    out, status = Open3.capture2e("ruby", Rails.root.join("bin/tool_usage").to_s, "--file", path, "--since", "2026-10-22")

    expect(status).to be_success
    expect(out).to include("期間: 2026-10-22 〜 2026-10-25（3回、2ツール）")
  end
end
