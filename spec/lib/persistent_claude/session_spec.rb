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
    expect(second[:structured]["reply"]).to eq("echo2")
    expect(session).to be_alive
  end

  it "sends the prompt of each turn as a user message" do
    session = start
    turn(session, "一つ目")
    turn(session, "二つ目")

    logged = File.readlines(log_path).map { |line| JSON.parse(line) }
    expect(logged.map { |entry| entry["content"] }).to eq(%w[一つ目 二つ目])
  end

  it "reports the size of what claude remembers, from the last API call of the turn" do
    session = start
    turn(session, "a")
    _, out = turn(session, "b")

    # 最後の assistant 行の usage（そのターンの最後の API 呼び出し）を使う: 1 + 2*10 + 2
    expect(out[:context_tokens]).to eq(23)
    expect(session.context_tokens).to eq(23)
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

    expect(parsed[:structured]["reply"]).to eq("echo1")
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

  it "does not reuse a claude whose turn was cut off before its answer was taken" do
    session = start
    thread = Thread.new { session.turn("SLOW", timeout: 20, idle_timeout: 10, poll_interval: 0.05) }
    sleep 0.4
    thread.kill
    thread.join

    expect(session).not_to be_alive
    expect(session).to be_retired
  end

  it "does not mix up a late answer with the next turn's answer" do
    session = start
    thread = Thread.new { session.turn("SLOW", timeout: 20, idle_timeout: 10, poll_interval: 0.05) }
    sleep 0.4
    thread.kill
    thread.join

    expect { turn(session, "二つ目") }.to raise_error(ClaudeCli::Error)
  end

  it "waits for background work even when the tracker sees the answer a moment later than the waiting side wakes" do
    slow_tracker_class = Class.new(ClaudeCli::Backends::Claude::BackgroundTracker) do
      def feed(line)
        sleep 0.3 if line.include?('"type":"result"')
        super
      end
    end
    session = start
    out = session.turn("BACKGROUND", background: slow_tracker_class.new, timeout: 20, idle_timeout: 10, poll_interval: 0.01)
    parsed = backend.parse(out[:stdout], out[:stderr], nil)

    expect(session).to be_retired
    expect(parsed[:followups].map { |f| f[:structured]["reply"] }).to eq([ "後報" ])
  end

  it "does not reuse a claude that starts background work outside a turn" do
    session = start
    turn(session, "BGLATE")
    expect(session).to be_alive

    sleep 0.6

    expect(session).to be_dirty
  end

  it "counts as busy from being claimed until its turn ends, so it is not closed in between" do
    session = start
    expect(session).not_to be_busy

    session.claim!
    expect(session).to be_busy

    turn(session, "x")
    expect(session).not_to be_busy
  end

  it "remembers which character and route file it belongs to" do
    session = described_class.new(
      key: "k", record_id: 1, cmd: [ Rails.root.join("spec/fixtures/bin/fake_persistent_claude").to_s ], env: {}, work_dir: dir,
      dir: File.join(dir, "session-r1"), events_path: events_path, character_id: 5, route_path: File.join(dir, "route.json")
    )
    sessions << session

    expect([ session.character_id, session.route_path ]).to eq([ 5, File.join(dir, "route.json") ])
  end
end
