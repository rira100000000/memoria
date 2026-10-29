require "open3"
require "json"
require "fileutils"

module PersistentClaude
  # 起動したままの claude -p を1本持ち、1往復ごとに user メッセージを送って答えを読む。
  #
  # claude -p は `--input-format stream-json` で起動すると、標準入力に JSON の user メッセージを1行ずつ
  # 受け取り、1往復ごとに result 行を出す。毎回起動し直すと、起動と MCP の接続で約2秒かかる。
  # 起動したままなら、起動は最初の1回だけで、プロンプトキャッシュも効く（1往復は1〜2秒）。
  #
  # このファイルは Rails の再読み込みの対象にしない（config/application.rb の autoload_lib で除外）。
  # 再読み込みで定数が作り直されると、動いている claude が誰からも参照されなくなるため。
  # 失敗は ClaudeCli::Error で上げる（Runner が使うものと同じ）。実行時に参照するだけで、読み込み時には使わない。
  class Session
    # ターンの外でこの種類の行が出たら、そのプロセスは「汚れた」とみなして使い回さない
    DIRTY_TYPES = %w[assistant result].freeze
    STDERR_TAIL_BYTES = 8192

    attr_reader :key, :record_id, :dir, :events_path, :long_think_path
    # { count:, tail:, ... } 常駐の claude が見た会話の範囲（ChatSession が更新する）
    attr_accessor :seen

    # @param cmd [Array<String>] claude の起動コマンド（--input-format stream-json を含む）
    def initialize(key:, record_id:, cmd:, env:, work_dir:, dir:, events_path:, long_think_path: nil)
      @key = key
      @record_id = record_id
      @dir = dir
      @events_path = events_path
      @long_think_path = long_think_path
      @seen = nil
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @turn_mutex = Mutex.new
      @lines = []
      @sinks = []
      @turn_active = false
      @answered = false
      @dirty = false
      @retire = false
      @eof = false
      @closed = false
      @stderr_tail = +""
      @last_output = now
      @last_used = now
      @context_tokens = 0
      spawn_process(cmd, env, work_dir)
    end

    # 1往復を、同時に1つだけにする（ふつうは ChatSession の排他で、すでに1つだけ）
    def synchronize(&block)
      @turn_mutex.synchronize(&block)
    end

    def alive?
      !@closed && !@dirty && !@retire && !@eof && @wait_thr.alive?
    end

    def busy?
      @mutex.synchronize { @turn_active }
    end

    def idle_seconds
      now - @last_used
    end

    # 直前の往復の時点の、claude が覚えている入力の大きさ（トークン）
    attr_reader :context_tokens

    # このターンのあと使い回さない（裏の作業が残った・文脈が大きくなりすぎた など）
    def retire!
      @retire = true
    end

    def retired?
      @retire
    end

    def dirty?
      @dirty
    end

    # 1往復する。
    # @param relay [#feed, #notify] ツールを使う前に書いた文を途中経過として渡す（ターンごとに新しく作る）
    # @param background [#feed, #waiting_tasks, #answered?] 裏の作業の追跡（ターンごとに新しく作る）
    # @param long_think [#read, nil] 長考の宣言（読むだけ。ターンの始めにファイルは消す）
    # @return [Hash] stdout: このターンの出力、stderr:、events_from: ツールの記録ファイルのこのターン開始時の位置、
    #   context_tokens:
    def turn(prompt, relay: nil, background: nil, long_think: nil, timeout:, idle_timeout:, poll_interval: 1)
      raise ClaudeCli::Error, "常駐の claude が使えません" unless alive?

      events_from = File.exist?(@events_path) ? File.size(@events_path) : 0
      File.delete(@long_think_path) if @long_think_path && File.exist?(@long_think_path)
      @mutex.synchronize do
        @lines = []
        @answered = false
        @sinks = [ relay, background ].compact
        @last_output = now
        @turn_active = true
      end
      send_user_message(prompt)
      wait_for_answer(relay, background, long_think, timeout, idle_timeout, poll_interval)

      stdout = @mutex.synchronize { @lines.join }
      @context_tokens = tokens_of(stdout)
      { stdout: stdout, stderr: stderr_text, events_from: events_from, context_tokens: @context_tokens }
    ensure
      @mutex.synchronize do
        @turn_active = false
        @sinks = []
      end
      @last_used = now
    end

    def close
      return if @closed

      @closed = true
      close_stdin
      kill_group unless @wait_thr.join(2)
      [ @reader, @err_reader ].each { |thread| thread&.join(1) || thread&.kill }
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    rescue Errno::ENOENT
      nil
    end

    private

    def spawn_process(cmd, env, work_dir)
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(env, *cmd, chdir: work_dir, pgroup: true)
      [ @stdin, @stdout, @stderr ].each { |io| io.set_encoding(Encoding::UTF_8) }
      @reader = Thread.new do
        @stdout.each_line { |line| handle_line(line) }
      rescue IOError
        nil
      ensure
        @mutex.synchronize do
          @eof = true
          @cond.broadcast
        end
      end
      @err_reader = Thread.new do
        @stderr.each_line do |line|
          @mutex.synchronize { @stderr_tail = tail_of(@stderr_tail + line) }
        end
      rescue IOError
        nil
      end
    rescue Errno::ENOENT
      raise ClaudeCli::Error, "#{cmd.first} コマンドが見つかりません"
    end

    def handle_line(line)
      type = line_type(line)
      sinks = nil
      @mutex.synchronize do
        @last_output = now
        if @turn_active
          @lines << line
          @answered = true if type == "result"
          sinks = @sinks
        elsif DIRTY_TYPES.include?(type)
          # ターンの外で動いた（裏の作業の知らせなど）。次のターンの答えと取り違えないよう、使い回さない
          @dirty = true
        end
        @cond.broadcast
      end
      sinks&.each { |sink| sink.feed(line) }
    end

    def line_type(line)
      return nil unless line.lstrip.start_with?("{")

      JSON.parse(line)["type"]
    rescue JSON::ParserError
      nil
    end

    def send_user_message(prompt)
      @stdin.write(JSON.generate(type: "user", message: { role: "user", content: prompt }) + "\n")
      @stdin.flush
    rescue IOError, Errno::EPIPE
      raise ClaudeCli::Error, "常駐の claude に送れませんでした（#{stderr_or('標準入力が閉じています')}）"
    end

    # 最初の result が出るまで待つ。答えのあとに裏の作業（run_in_background）が残っていたら、入力を閉じて
    # 終わるまで待ち（claude -p は裏の作業が終わると、その知らせで動いて答えをもう1つ出して終わる）、この claude は使い回さない
    def wait_for_answer(relay, background, long_think, timeout, idle_timeout, poll_interval)
      started = now
      announced = nil
      announced_tasks = nil
      draining = false
      loop do
        answered, eof, last_output = @mutex.synchronize { [ @answered, @eof, @last_output ] }
        waiting = answered ? (background&.waiting_tasks || []) : []
        if answered && waiting.empty? && !draining
          return
        elsif answered && !draining
          draining = true
          @retire = true
          close_stdin
        end
        if eof
          return if answered

          raise ClaudeCli::Error, "claude が途中で終了しました（#{stderr_or('出力なし')}）"
        end

        declaration = long_think&.read
        if declaration && declaration != announced
          announced = declaration
          relay&.notify("長考中（〜#{declaration.minutes}分：#{declaration.reason}）")
        end
        if waiting.any? && waiting != announced_tasks
          announced_tasks = waiting
          relay&.notify("裏の作業が終わるのを待ってる（#{waiting.join("、")}）")
        end

        if now - started > timeout
          return stop_after_answer if answered

          raise ClaudeCli::Error, "#{duration_text(timeout)}たっても終わらなかったので止めました"
        end
        unless (declaration && Time.now < declaration.until_time) || waiting.any?
          idle = now - last_output
          idle = [ idle, Time.now - declaration.until_time ].min if declaration
          if idle > idle_timeout
            return stop_after_answer if answered

            raise ClaudeCli::Error, "#{duration_text(idle_timeout)}出力がなかったので止めました"
          end
        end
        @mutex.synchronize { @cond.wait(@mutex, poll_interval) }
      end
    end

    # 答えが出たあとに時間切れになったとき: 残った作業を止めて、そこまでの出力（答え）を使う
    def stop_after_answer
      @retire = true
      kill_group
    end

    def close_stdin
      @stdin.close unless @stdin.closed?
    rescue IOError
      nil
    end

    def kill_group
      Process.kill("TERM", -@wait_thr.pid)
      @wait_thr.join(2)
      Process.kill("KILL", -@wait_thr.pid) if @wait_thr.alive?
    rescue Errno::ESRCH
      nil
    end

    # このターンの最後の result 行の usage から、claude が覚えている入力の大きさを出す
    def tokens_of(stdout)
      usage = stdout.each_line.filter_map { |line| JSON.parse(line) if line.lstrip.start_with?("{") }
        .select { |m| m["type"] == "result" }.last&.dig("usage")
      return 0 unless usage.is_a?(Hash)

      %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].sum { |name| usage[name].to_i }
    rescue JSON::ParserError
      0
    end

    def stderr_text
      @mutex.synchronize { @stderr_tail.strip }
    end

    def stderr_or(default)
      text = stderr_text
      text.empty? ? default : text
    end

    def tail_of(text)
      text.length > STDERR_TAIL_BYTES ? text[-STDERR_TAIL_BYTES..] : text
    end

    def duration_text(seconds)
      return "#{seconds / 3600}時間" if seconds >= 3600 && (seconds % 3600).zero?
      return "#{seconds / 60}分" if seconds >= 60 && (seconds % 60).zero?

      "#{seconds}秒"
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
