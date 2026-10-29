require_relative "session"

module PersistentClaude
  # 常駐の claude（Session）を、会話ごとに1本ずつ持つ。鍵（key）には会話の記録（ChatSessionRecord）の id や
  # モデル、起動時に固定される値の指紋が入る。使われなくなったものは一定時間で止め、プロセスの終了時にすべて止める。
  #
  # 1つの Rails プロセスに1つ（Pool.instance）。このファイルは Rails の再読み込みの対象にしない
  # （config/application.rb の autoload_lib で除外）。
  class Pool
    DEFAULT_IDLE_SECONDS = 3600
    DEFAULT_MAX_SESSIONS = 4
    REAP_INTERVAL = 30

    def self.instance
      @instance ||= new
    end

    def initialize(idle_seconds: Integer(ENV.fetch("CLAUDE_CLI_PERSISTENT_IDLE", DEFAULT_IDLE_SECONDS)),
                   max_sessions: Integer(ENV.fetch("CLAUDE_CLI_PERSISTENT_MAX", DEFAULT_MAX_SESSIONS)))
      @idle_seconds = idle_seconds
      @max_sessions = max_sessions
      @sessions = {}
      @mutex = Mutex.new
      @reaper = nil
      @at_exit_registered = false
    end

    # 使える常駐の claude を返す（なければ nil）。使えなくなったもの（落ちた・汚れた・使い回さない）は、ここで片づける
    def fetch(key)
      stale = nil
      session = @mutex.synchronize do
        found = @sessions[key]
        if found && !found.alive?
          stale = @sessions.delete(key)
          found = nil
        end
        found
      end
      stale&.close
      session
    end

    def put(session)
      evicted = []
      @mutex.synchronize do
        @sessions[session.key] = session
        evicted = take_over_limit
      end
      evicted.each(&:close)
      start_reaper
      register_at_exit
      session
    end

    # 捨てる（失敗したとき、使い回さないとき）
    def discard(session)
      @mutex.synchronize { @sessions.delete(session.key) if @sessions[session.key].equal?(session) }
      session.close
    end

    # 同じ会話の記録の、鍵が違う常駐を止める（強いモデルに切り替えたとき、人格などの指紋が変わったとき）
    def release_record(record_id, except: nil)
      doomed = @mutex.synchronize do
        @sessions.select { |key, session| session.record_id == record_id && key != except && !session.busy? }.keys
          .map { |key| @sessions.delete(key) }
      end
      doomed.each(&:close)
    end

    def size
      @mutex.synchronize { @sessions.size }
    end

    # 使われなくなったものを止める
    def reap
      doomed = @mutex.synchronize do
        @sessions.select { |_key, session| !session.busy? && (session.idle_seconds > @idle_seconds || !session.alive?) }.keys
          .map { |key| @sessions.delete(key) }
      end
      doomed.each(&:close)
    end

    def shutdown
      all = @mutex.synchronize { @sessions.values.tap { @sessions.clear } }
      all.each(&:close)
    end

    private

    # 上限を超えたら、使われていない中でいちばん古いものから外す
    def take_over_limit
      evicted = []
      while @sessions.size > @max_sessions
        candidate = @sessions.values.reject(&:busy?).max_by(&:idle_seconds)
        break unless candidate

        evicted << @sessions.delete(candidate.key)
      end
      evicted
    end

    def start_reaper
      return if @reaper&.alive?

      @reaper = Thread.new do
        loop do
          sleep REAP_INTERVAL
          reap
        end
      end
      @reaper.report_on_exception = false
    end

    def register_at_exit
      return if @at_exit_registered

      @at_exit_registered = true
      at_exit { shutdown }
    end
  end
end
