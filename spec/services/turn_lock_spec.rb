require "rails_helper"

RSpec.describe TurnLock do
  let(:dir) { Dir.mktmpdir }

  def lock(character_id = 1, **options)
    described_class.new(character_id, directory: dir, **options)
  end

  describe ".directory_for（純粋関数）" do
    it "環境変数の指定を最優先する" do
      expect(described_class.directory_for(env_dir: "/x/locks", db_dir: "/db", fallback: "/tmp/f")).to eq("/x/locks")
    end

    it "指定がなければ、DB の隣の locks を使う" do
      expect(described_class.directory_for(env_dir: nil, db_dir: "/db", fallback: "/tmp/f")).to eq("/db/locks")
      expect(described_class.directory_for(env_dir: " ", db_dir: "/db", fallback: "/tmp/f")).to eq("/db/locks")
    end

    it "どちらもなければ、最後の手段を使う" do
      expect(described_class.directory_for(env_dir: nil, db_dir: nil, fallback: "/tmp/f")).to eq("/tmp/f")
    end

    it "同じ入力には同じ出力を返す" do
      args = { env_dir: nil, db_dir: "/db", fallback: "/f" }
      expect(described_class.directory_for(**args)).to eq(described_class.directory_for(**args))
    end
  end

  describe ".file_name（純粋関数）" do
    it "キャラクターごとに別のファイル名になる" do
      expect(described_class.file_name(3)).to eq("chat-3.lock")
      expect(described_class.file_name(3)).not_to eq(described_class.file_name(4))
    end
  end

  describe ".default_directory" do
    it "作業ツリーが違っても、同じ DB（シンボリックリンク先）を見れば同じ場所になる" do
      real = Dir.mktmpdir
      File.write(File.join(real, "x.sqlite3"), "")
      link_dir = Dir.mktmpdir
      File.symlink(File.join(real, "x.sqlite3"), File.join(link_dir, "x.sqlite3"))
      allow(ActiveRecord::Base.connection_db_config).to receive(:database).and_return(File.join(link_dir, "x.sqlite3"))
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("MEMORIA_LOCK_DIR").and_return(nil)

      expect(described_class.default_directory).to eq(File.join(File.realpath(real), "locks"))
    end

    it "MEMORIA_LOCK_DIR があればそれを使う" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("MEMORIA_LOCK_DIR").and_return("/custom")
      expect(described_class.default_directory).to eq("/custom")
    end
  end

  describe "#synchronize" do
    it "ブロックの値を返す" do
      expect(lock.synchronize { :done }).to eq(:done)
    end

    it "同じキャラクターでは、同時に1つだけがブロックを実行する" do
      inside = 0
      max_inside = 0
      mutex = Mutex.new
      threads = 4.times.map do
        Thread.new do
          lock(1, wait: 10).synchronize do
            mutex.synchronize { inside += 1; max_inside = [ max_inside, inside ].max }
            sleep 0.05
            mutex.synchronize { inside -= 1 }
          end
        end
      end
      threads.each(&:join)

      expect(max_inside).to eq(1)
    end

    it "別のキャラクターは互いを待たせない" do
      entered = Queue.new
      release = Queue.new
      holder = Thread.new { lock(1).synchronize { entered << true; release.pop } }
      entered.pop

      expect(lock(2, wait: 0).synchronize { :ok }).to eq(:ok)
      release << true
      holder.join
    end

    it "別のプロセスが持っているあいだ、待っても取れなければ Busy を上げてブロックを実行しない" do
      dir # fork の前に決める（子で別の場所にならないように）
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        lock(1).synchronize { writer.puts("locked"); sleep 5 }
      ensure
        exit!(0)
      end
      writer.close
      reader.gets
      ran = false

      expect { lock(1, wait: 0.2).synchronize { ran = true } }.to raise_error(TurnLock::Busy, /待っても終わりませんでした/)
      expect(ran).to be(false)
    ensure
      Process.kill("KILL", pid) if pid
      Process.wait(pid) if pid
    end

    it "待つ時計と待ち方は差し替えられる（待ち時間の判断をテストできる）" do
      times = [ 0, 1, 2, 10 ].each
      sleeps = []
      held = File.open(File.join(dir, TurnLock.file_name(1)), File::RDWR | File::CREAT)
      held.flock(File::LOCK_EX)

      expect do
        lock(1, wait: 5, clock: -> { times.next }, sleeper: ->(s) { sleeps << s }).synchronize { :never }
      end.to raise_error(TurnLock::Busy)
      expect(sleeps).to eq([ 0.5, 0.5 ])
    ensure
      held&.close
    end

    it "例外でブロックを抜けても、ロックと「持っている」印を外す" do
      expect { lock.synchronize { raise "boom" } }.to raise_error("boom")

      expect(TurnLock.held).to be_empty
      expect(lock(1, wait: 0).synchronize { :again }).to eq(:again)
    end

    it "同じスレッドの入れ子は、待たずに通す" do
      result = lock(1, wait: 0).synchronize { lock(1, wait: 0).synchronize { :inner } }

      expect(result).to eq(:inner)
    end
  end
end
