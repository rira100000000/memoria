require "rails_helper"

RSpec.describe PersistentClaude::Pool do
  let(:dir) { Dir.mktmpdir("pool-spec") }
  let(:pool) { described_class.new(idle_seconds: 3600, max_sessions: 5) }

  after do
    pool.shutdown
    FileUtils.remove_entry(dir) if File.exist?(dir)
  end

  def build(key, record_id: 1)
    session_dir = File.join(dir, key)
    FileUtils.mkdir_p(session_dir)
    PersistentClaude::Session.new(
      key: key, record_id: record_id, cmd: [ Rails.root.join("spec/fixtures/bin/fake_persistent_claude").to_s ], env: {},
      work_dir: dir, dir: session_dir, events_path: File.join(session_dir, "events.jsonl")
    )
  end

  it "returns the session stored under a key, and nothing for an unknown key" do
    session = pool.put(build("a"))

    expect(pool.fetch("a")).to equal(session)
    expect(pool.fetch("none")).to be_nil
    expect(pool.size).to eq(1)
  end

  it "drops and closes a session that is no longer usable when it is fetched" do
    session = pool.put(build("a"))
    session.retire!

    expect(pool.fetch("a")).to be_nil
    expect(pool.size).to eq(0)
    expect(File.exist?(File.join(dir, "a"))).to be(false)
  end

  it "closes a discarded session" do
    session = pool.put(build("a"))

    pool.discard(session)

    expect(pool.size).to eq(0)
    expect(session).not_to be_alive
  end

  it "releases the other sessions of the same conversation record, but not other records" do
    mine = pool.put(build("mine", record_id: 7))
    other_key = pool.put(build("other-key", record_id: 7))
    other_record = pool.put(build("other-record", record_id: 8))

    pool.release_record(7, except: "mine")

    expect(pool.fetch("mine")).to equal(mine)
    expect(other_key).not_to be_alive
    expect(pool.fetch("other-record")).to equal(other_record)
  end

  it "evicts the longest idle session when over the limit" do
    small = described_class.new(idle_seconds: 3600, max_sessions: 2)
    first = small.put(build("first"))
    sleep 0.05
    small.put(build("second"))
    sleep 0.05
    small.put(build("third"))

    expect(small.size).to eq(2)
    expect(first).not_to be_alive
  ensure
    small&.shutdown
  end

  it "reaps sessions idle for too long and keeps the others" do
    quick = described_class.new(idle_seconds: 0, max_sessions: 4)
    old = quick.put(build("old"))
    sleep 0.05

    quick.reap

    expect(quick.size).to eq(0)
    expect(old).not_to be_alive
  ensure
    quick&.shutdown
  end

  it "does not reap a session that is in the middle of a turn" do
    quick = described_class.new(idle_seconds: 0, max_sessions: 4)
    session = quick.put(build("busy"))
    allow(session).to receive(:busy?).and_return(true)
    sleep 0.05

    quick.reap

    expect(quick.size).to eq(1)
  ensure
    quick&.shutdown
  end

  it "closes everything on shutdown, so no claude is left behind" do
    sessions = %w[a b].map { |key| pool.put(build(key)) }

    pool.shutdown

    expect(pool.size).to eq(0)
    expect(sessions).to all(satisfy { |session| !session.alive? })
  end

  it "has one shared instance" do
    expect(described_class.instance).to equal(described_class.instance)
  end
end
