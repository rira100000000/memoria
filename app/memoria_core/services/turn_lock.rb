require "fileutils"
require "tmpdir"

# 1人のキャラクターが一度に1つのことしか話さないための、プロセスをまたぐ排他（ファイルロック）。
#
# 契約:
# - 事前条件: character_id は、キャラクターを一意に表す値。wait は 0 以上の秒数（または ActiveSupport::Duration）
# - 保証: synchronize のブロックを実行しているのは、同じ directory を見るすべてのプロセス・スレッドのうち、
#   同じ character_id では1つだけ（同じスレッドの入れ子は、すでに持っているものとして通す）
# - 保証: wait の間に取れなければ Busy を上げ、ブロックは実行しない
# - 保証: ブロックが終わる（例外でも）と、ロックと「持っている」印は必ず外れる
# - 不変条件: ロックの場所は作業ツリーに依存しない（DB の隣。TurnLock.directory_for）。
#   作業ツリーが違うプロセスどうし（main と worktree）でも、同じ DB を使うなら同じロックを見る
#
# 副作用（ファイル・時計・待ち）は synchronize と default_directory に閉じ込め、
# 場所と名前の決定（directory_for・file_name）は純粋関数にしてある。
class TurnLock
  class Busy < StandardError; end

  POLL_INTERVAL = 0.5

  # 純粋関数: ロックを置くディレクトリを決める。環境変数の指定 > DB の隣 > 最後の手段
  # @param env_dir [String, nil] 明示の指定（MEMORIA_LOCK_DIR）
  # @param db_dir [String, nil] DB ファイルがある実際のディレクトリ（シンボリックリンクをたどったあと）
  # @param fallback [String]
  # @return [String]
  def self.directory_for(env_dir:, db_dir:, fallback:)
    return env_dir unless env_dir.nil? || env_dir.strip.empty?
    return File.join(db_dir, "locks") unless db_dir.nil? || db_dir.strip.empty?

    fallback
  end

  # 純粋関数: ロックのファイル名
  def self.file_name(character_id)
    "chat-#{character_id}.lock"
  end

  # 副作用（環境変数と DB の設定、ファイルの実体を見る）を持つ入口。判断は directory_for に任せる
  def self.default_directory
    directory_for(env_dir: ENV["MEMORIA_LOCK_DIR"], db_dir: database_directory, fallback: File.join(Dir.tmpdir, "memoria-locks"))
  end

  def self.database_directory
    return nil unless defined?(ActiveRecord::Base)

    database = ActiveRecord::Base.connection_db_config.database.to_s
    return nil if database.empty? || database == ":memory:"

    path = defined?(Rails) && Rails.root ? Rails.root.join(database).to_s : File.expand_path(database)
    File.dirname(File.realpath(path))
  rescue ActiveRecord::ActiveRecordError, Errno::ENOENT
    nil
  end

  # 同じスレッドが持っている character_id（入れ子を通すため）
  def self.held
    Thread.current[:memoria_turn_locks] ||= []
  end

  def initialize(character_id, label: nil, directory: self.class.default_directory, wait: 30 * 60, clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) })
    @character_id = character_id
    @label = label || "キャラクター##{character_id}"
    @directory = directory
    @wait = wait.to_f
    @clock = clock
    @sleeper = sleeper
  end

  def path
    File.join(@directory, self.class.file_name(@character_id))
  end

  def synchronize
    return yield if self.class.held.include?(@character_id)

    FileUtils.mkdir_p(@directory)
    File.open(path, File::RDWR | File::CREAT) do |file|
      acquire(file)
      self.class.held << @character_id
      begin
        yield
      ensure
        self.class.held.delete(@character_id)
      end
    end
  end

  private

  def acquire(file)
    deadline = @clock.call + @wait
    until file.flock(File::LOCK_EX | File::LOCK_NB)
      raise Busy, "#{@label}は別の返答をしていて、#{@wait.to_i}秒待っても終わりませんでした" if @clock.call > deadline

      @sleeper.call(POLL_INTERVAL)
    end
  end
end
