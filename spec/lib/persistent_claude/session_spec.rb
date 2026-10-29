require "rails_helper"
require Rails.root.join("lib/persistent_claude/pool")

RSpec.describe PersistentClaude::Session do
  let(:dir) { Dir.mktmpdir("persistent-spec") }
  let(:log_path) { File.join(dir, "fake.log") }
  let(:events_path) { File.join(dir, "tool_events.jsonl") }
  let(:long_think_path) { File.join(dir, "long_think.json") }
  let(:backend) { ClaudeCli::Backends::Claude.new(command: "x", max_turns: 5) }
  let(:sessions) { [] }

  after do
    sessions.each(&:close)
    FileUtils.remove_entry(dir) if File.exist?(dir)
  end

  def start(key: "r1")
    session = described_class.new(
      key: key, record_id: 1, cmd: [ Rails.root.join("spec/fixtures/bin/fake_persistent_claude").to_s ],
      env: { "FAKE_CLAUDE_LOG" => log_path }, work_dir: dir, dir: File.join(dir, "session-#{key}"),
      events_path: events_path, long_think_path: long_think_path
    )
    sessions << session
    session
  end

  def turn(session, text, **opts)
    relay = opts.delete(:relay)
    background = backend.background_tracker
    out = session.turn(text, relay: relay, background: background, timeout: 20, idle_timeout: 10, poll_interval: 0.05, **opts)
    [ backend.parse(out[:stdout], out[:stderr], nil), out ]
  end

  def pid_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  before { FileUtils.mkdir_p(File.join(dir, "session-r1")) }

  it "answers several turns from the same process" do
    session = start
    first, = turn(session, "こんにちは")
    second, = turn(session, "元気？")
    third, = turn(session, "またね")

    expect([ first, second, third ].map { |r| r[:structured]["n"] }).to eq([ 1, 2, 3 ])
    expect([ first, second, third ].map { |r| r[:structured]["pid"] }.uniq.size).to eq(1)
    expect(second[:structured]["reply"]).to eq("echo2:元気？")
    expect(session).to be_alive
  end

  it "sends the prompt of each turn as a user message" do
    session = start
    turn(session, "一つ目")
    turn(session, "二つ目")

    logged = File.readlines(log_path).map { |line| JSON.parse(line) }
    expect(logged.map { |entry| entry["content"] }).to eq(%w[一つ目 二つ目])
  end

  it "reports the size of what claude remembers, from the last result" do
    session = start
    turn(session, "a")
    _, out = turn(session, "b")

    expect(out[:context_tokens]).to eq(3 + 200 + 10)
    expect(session.context_tokens).to eq(213)
  end

  it "tells where this turn's tool events start in the events file" do
    File.write(events_path, "{\"name\":\"old\"}\n")
    session = start

    _, out = turn(session, "x")

    expect(out[:events_from]).to eq(File.size(events_path))
  end

  it "clears a long-think declaration left by the previous turn" do
    File.write(long_think_path, "{}")
    session = start

    turn(session, "x")

    expect(File.exist?(long_think_path)).to be(false)
  end

  it "raises when the process dies in the middle of a turn, and is no longer usable" do
    session = start

    expect { turn(session, "CRASH") }.to raise_error(ClaudeCli::Error, /途中で終了.*boom/)
    expect(session).not_to be_alive
  end

  it "stops waiting when nothing is output for too long, and raises" do
    session = start

    expect { session.turn("SLOW", timeout: 20, idle_timeout: 1, poll_interval: 0.05) }
      .to raise_error(ClaudeCli::Error, /出力がなかったので止めました/)
  end

  it "stops at the overall time limit" do
    session = start

    expect { session.turn("SLOW", timeout: 1, idle_timeout: 30, poll_interval: 0.05) }
      .to raise_error(ClaudeCli::Error, /たっても終わらなかったので止めました/)
  end

  it "marks itself dirty when something is output outside a turn, so it is not reused" do
    session = start
    turn(session, "UNSOLICITED")
    expect(session).to be_alive

    sleep 0.6

    expect(session).to be_dirty
    expect(session).not_to be_alive
  end

  it "waits for background work, returns the follow-up answer too, and retires" do
    session = start
    relay_texts = []
    relay = backend.progress_relay(->(text) { relay_texts << text })

    parsed, = turn(session, "BACKGROUND", relay: relay)

    expect(parsed[:structured]["reply"]).to start_with("echo1:BACKGROUND")
    expect(parsed[:followups].map { |f| f[:structured]["reply"] }).to eq([ "後報" ])
    expect(session).to be_retired
    expect(session).not_to be_alive
  end

  it "does not let a second turn run while the first is running" do
    session = start
    order = []
    thread = Thread.new { session.synchronize { order << :first_start; turn(session, "SLOW"); order << :first_end } }
    sleep 0.3
    session.synchronize { order << :second }
    thread.join

    expect(order).to eq(%i[first_start first_end second])
  end

  it "stops the process and removes its directory on close" do
    session = start
    parsed, = turn(session, "x")
    pid = parsed[:structured]["pid"]

    session.close

    expect(pid_alive?(pid)).to be(false)
    expect(File.exist?(File.join(dir, "session-r1"))).to be(false)
    expect(session).not_to be_alive
  end

  it "raises a clear error when the command does not exist" do
    expect {
      described_class.new(key: "x", record_id: 1, cmd: [ "/nonexistent/claude" ], env: {}, work_dir: dir, dir: File.join(dir, "s"), events_path: events_path)
    }.to raise_error(ClaudeCli::Error, /見つかりません/)
  end
end
