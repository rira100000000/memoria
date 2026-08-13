require "rails_helper"
require "fileutils"
require "sqlite3"

RSpec.describe DbBackupJob, type: :job do
  let(:fake_storage) { Rails.root.join("tmp/spec_storage_#{SecureRandom.hex(4)}") }

  before do
    FileUtils.mkdir_p(fake_storage)
    stub_const("DbBackupJob::STORAGE_ROOT", fake_storage)
  end

  after do
    FileUtils.rm_rf(fake_storage)
  end

  it "is enqueued in the low queue" do
    expect(described_class.new.queue_name).to eq("low")
  end

  describe "#perform" do
    def make_fake_db(name, rows: 3)
      path = fake_storage.join(name).to_s
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE foo (id INTEGER)")
      rows.times { |i| db.execute("INSERT INTO foo VALUES (?)", [i]) }
      db.close
      path
    end

    it "snapshots every sqlite file in storage/" do
      make_fake_db("primary.sqlite3")
      make_fake_db("queue.sqlite3", rows: 5)

      described_class.new.perform

      backup_dirs = Dir[fake_storage.join("backups", "*").to_s]
      expect(backup_dirs.size).to eq(1)

      snapshots = Dir[File.join(backup_dirs.first, "*.sqlite3")].map { |p| File.basename(p) }
      expect(snapshots).to contain_exactly("primary.sqlite3", "queue.sqlite3")

      # スナップショットの中身が読める
      restored = SQLite3::Database.new(File.join(backup_dirs.first, "queue.sqlite3"))
      expect(restored.execute("SELECT COUNT(*) FROM foo").first.first).to eq(5)
      restored.close
    end

    it "is a no-op when storage has no sqlite files" do
      expect { described_class.new.perform }.not_to raise_error
      expect(Dir[fake_storage.join("backups", "*").to_s]).to be_empty
    end

    it "prunes snapshots older than KEEP" do
      stub_const("DbBackupJob::KEEP", 2)

      # 既存の古いスナップショットを 3 つ作る
      %w[20260101_000000 20260102_000000 20260103_000000].each do |name|
        FileUtils.mkdir_p(fake_storage.join("backups", name))
      end

      make_fake_db("primary.sqlite3")
      described_class.new.perform

      remaining = Dir[fake_storage.join("backups", "*").to_s].sort
      # KEEP=2 なので、新しい 1 つ + 既存の 1 つの計 2 つだけ残る
      expect(remaining.size).to eq(2)
      expect(remaining.last).to include(Time.current.strftime("%Y%m%d"))
    end
  end
end
