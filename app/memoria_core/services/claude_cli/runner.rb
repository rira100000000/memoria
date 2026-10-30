require "open3"
require "tmpdir"
require "digest"

module ClaudeCli
  # claude -p（または codex exec）を1回実行する。どちらで動かすかは LLM_CLI_BACKEND で決める
  # （claude / codex。未設定なら claude）。コマンドの組み立てと出力の読み方は Backends::Claude / Backends::Codex にある。
  #
  # キャラクターを指定したときは、そのツールを MCP サーバ（bin/memoria_mcp）として渡す。
  # MCP サーバは実行したツールの記録を一時ファイル（JSON Lines）に書き、ここで読み戻して返す。
  # 組み込みツールは、既定では読むだけのもの（WebSearch・WebFetch）をキャラクターのツールと
  # 一緒に使わせる。CLAUDE_CLI_BUILTIN_TOOLS=default にすると全部使わせる（claude の権限は CLAUDE_CLI_SETTINGS の
  # 設定ファイルで、codex はサンドボックス CODEX_CLI_SANDBOX で決める）。キャラクターごとに変えるときは
  # CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER に "vault_dir_name=ツール,ツール;vault_dir_name=default" の形で書く
  # （"vault_dir_name=" なら使わせない）。
  # 作業ディレクトリは CLAUDE_CLI_WORKDIR（未設定なら空の一時ディレクトリ）。
  # 出力が CLAUDE_CLI_IDLE_TIMEOUT 秒とぎれたら止める。キャラクターが long_think ツールで長考を宣言したら、
  # その期限までは出力がなくても止めない。答えのあと裏の作業（run_in_background）が終わるのを待っている間も止めない。
  # 経過時間の上限 CLAUDE_CLI_TIMEOUT は安全弁として残す（答えが出ていれば、止めても答えは返す）。
  # 利用者の Claude Code / Codex の設定ファイルは読まない。
  class Runner
    # session_key: 常駐の claude を使ったときの、その鍵（ChatSession が、見た会話の範囲を覚えさせるのに使う）
    Result = Struct.new(:text, :tool_events, :model, :structured, :followups, :session_key, keyword_init: true)

    # 経過時間の上限（安全弁）
    DEFAULT_TIMEOUT = 7200
    # 出力がこれだけとぎれたら止める
    DEFAULT_IDLE_TIMEOUT = 600
    # 止まっていないかを見る間隔
    POLL_INTERVAL = 1
    DEFAULT_MAX_TURNS = 20
    # キャラクターのツールと一緒に使わせる組み込みツール（読むだけのもの）
    DEFAULT_BUILTIN_TOOLS = "WebSearch,WebFetch"
    # 常駐の claude が覚えている入力がこのトークン数を超えたら、使い回さず、次は会話の履歴から起動し直す
    DEFAULT_MAX_CONTEXT = 120_000

    attr_reader :backend

    # @param backend [String, Symbol, #command_line] "claude" / "codex"、またはバックエンドそのもの
    # @param command [String, nil] 実行するコマンド（未設定なら CLAUDE_CLI_COMMAND / CODEX_CLI_COMMAND）
    def initialize(backend: ClaudeCli.backend,
                   command: nil,
                   timeout: ENV.fetch("CLAUDE_CLI_TIMEOUT", DEFAULT_TIMEOUT).to_i,
                   idle_timeout: ENV.fetch("CLAUDE_CLI_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT).to_i,
                   poll_interval: POLL_INTERVAL,
                   max_turns: ENV.fetch("CLAUDE_CLI_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
                   builtin_tools: ENV.fetch("CLAUDE_CLI_BUILTIN_TOOLS", DEFAULT_BUILTIN_TOOLS),
                   builtin_tools_by_character: ENV["CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER"],
                   work_dir: ENV["CLAUDE_CLI_WORKDIR"].presence,
                   settings: ENV["CLAUDE_CLI_SETTINGS"].presence,
                   codex_home: ENV["CODEX_CLI_HOME"].presence,
                   codex_sandbox: ENV["CODEX_CLI_SANDBOX"].presence,
                   mcp_command: Rails.root.join("bin/memoria_mcp").to_s,
                   lazy_mcp: ENV.fetch("CLAUDE_CLI_LAZY_MCP", "0") == "1",
                   persistent: ClaudeCli.persistent?,
                   max_context: ENV.fetch("CLAUDE_CLI_PERSISTENT_MAX_CONTEXT", DEFAULT_MAX_CONTEXT).to_i)
      @backend =
        case backend.to_s
        when "codex"
          Backends::Codex.new(command: command || ENV.fetch("CODEX_CLI_COMMAND", "codex"), home: codex_home,
                              sandbox: codex_sandbox, tool_timeout: idle_timeout)
        when "claude", ""
          Backends::Claude.new(command: command || ENV.fetch("CLAUDE_CLI_COMMAND", "claude"), max_turns: max_turns, settings: settings)
        else
          raise ArgumentError, "unknown backend: #{backend}" unless backend.respond_to?(:command_line)

          backend
        end
      @work_dir = work_dir
      @builtin_tools = tool_list(builtin_tools)
      @builtin_tools_by_character = builtin_tools_by_character.to_s.split(";").filter_map { |entry|
        key, tools = entry.split("=", 2)
        [key.strip, tool_list(tools)] if key.to_s.strip.present? && tools
      }.to_h
      @timeout = timeout
      @idle_timeout = idle_timeout
      @poll_interval = poll_interval
      @mcp_command = mcp_command
      @lazy_mcp = lazy_mcp
      @settings = settings
      @persistent = persistent && @backend.is_a?(Backends::Claude)
      @max_context = max_context
    end

    # @param character [Character, nil] 指定するとそのキャラクターのツールを MCP で渡す。nil ならツールなし
    # @param scene [Symbol] :chat / :thinking（MCP サーバが出すツールが変わる）
    # @param trigger_type [String] ツール内の Gemini 呼び出し（埋め込みなど）を ApiUsageLog に記録するときの区分
    # @param on_progress [#call, nil] ツールを使う前に書いた文（「調べてみるね」など）を、終わるのを待たずに受け取る
    # @param json_schema [Hash, nil] 指定すると、この形で答えさせる（Result#structured に入る）
    # @param usage_context [Hash, nil] ツールの使用記録（ToolUsageLog）に添える場面の情報（予定の { wakeup_id:, purpose: }）
    # @return [Result] text: 最終応答、tool_events: [{ name:, args:, result: }]、structured: json_schema の形の答え、
    #   followups: 答えのあと、裏の作業が終わった知らせで動いて出した答え（[{ text:, structured: }]）
    # @param persistence [Hash, nil] 会話のあいだ claude を起動したままにするとき（ChatSession が渡す）:
    #   record_id: 会話の記録の id、verify: 常駐の claude が見た範囲（seen）が今の履歴と合っているか、
    #   fresh_prompt: 起動し直したときに渡すプロンプト（会話の全文）、resume_prompt: 使い回すときに渡すプロンプト（見た範囲の続きだけ）
    def run(system_prompt:, prompt:, model:, character: nil, scene: nil, trigger_type: nil, platform: nil, on_progress: nil, json_schema: nil, usage_context: nil, persistence: nil)
      if persistence && !persistent_run?(character, scene, json_schema)
        # ChatSession は常駐のつもりで system prompt から時刻と記憶を抜いている。従来の経路に黙って落とすと、それらがどこにも入らない
        raise ArgumentError, "persistence was given but this runner cannot keep claude running (CLAUDE_CLI_PERSISTENT, the chat scene and json_schema are required)"
      end
      if persistence
        return run_persistent(system_prompt: system_prompt, model: model, character: character, scene: scene, platform: platform,
                              on_progress: on_progress, json_schema: json_schema, persistence: persistence)
      end

      Dir.mktmpdir("memoria-claude") do |dir|
        events_path = File.join(dir, "tool_events.jsonl")
        long_think = LongThink.new(File.join(dir, "long_think.json"))
        work_dir = File.join(dir, "work")
        Dir.mkdir(work_dir)

        tools_path = character && write_tool_list(dir, character, scene, platform, long_think)
        config = character && mcp_config(character, scene, platform, trigger_type, events_path, long_think, usage_context, tools_path)

        # キャラクターとして動くときだけ、指定された作業ディレクトリで動かす（軽い作業は空のディレクトリ）
        work_dir = @work_dir if character && @work_dir
        relay = on_progress && @backend.progress_relay(on_progress)
        background = @backend.respond_to?(:background_tracker) ? @backend.background_tracker : nil
        builtin = character ? @builtin_tools_by_character.fetch(character.vault_dir_name, @builtin_tools) : []
        cmd = @backend.command_line(dir: dir, system_prompt: system_prompt, model: model, mcp_config: config,
                                    builtin: builtin, json_schema: json_schema)
        stdout, stderr, status = execute(cmd, prompt, work_dir, relay, long_think: character && long_think, background: background)
        parsed = @backend.parse(stdout, stderr, status, json_schema: json_schema)

        Result.new(text: parsed[:text], tool_events: read_events(events_path) + parsed[:builtin_events], model: model,
                   structured: parsed[:structured], followups: parsed[:followups] || [])
      end
    end

    private

    # 会話の返答（構造化された答えを返す場面）だけを、起動したままの claude で動かす
    def persistent_run?(character, scene, json_schema)
      @persistent && character && scene.to_s == "chat" && json_schema
    end

    def run_persistent(system_prompt:, model:, character:, scene:, platform:, on_progress:, json_schema:, persistence:)
      pool = PersistentClaude::Pool.instance
      builtin = @builtin_tools_by_character.fetch(character.vault_dir_name, @builtin_tools)
      route = persistence[:route] || ConversationRoute.new(platform: platform)
      key = persistent_key(persistence[:record_id], character, scene, model, system_prompt, json_schema, builtin)
      # 同じ会話の、鍵が違うもの（強いモデルへの切り替え・人格などの変更で古くなったもの）は、その場で止める。
      # 同じキャラクターの、ほかの会話の記録のもの（閉じた会話）も止める
      pool.release_record(persistence[:record_id], except: key)
      pool.release_character(character.id, except_record: persistence[:record_id])
      session = pool.fetch(key, claim: true)
      if session && !persistence[:verify].call(session.seen)
        pool.discard(session)
        session = nil
      end
      fresh = session.nil?
      session ||= spawn_persistent(key, persistence[:record_id], system_prompt, model, character, scene, json_schema, builtin).tap(&:claim!)
      begin
        prompt = fresh ? persistence[:fresh_prompt].call : persistence[:resume_prompt].call(session.seen)
        # 返答を会話の記録に追記し終えるまで（ChatSession が seen を進めるまで）は、見た範囲を空にしておく。
        # 追記の前に例外が出ても、次のターンの照合が通らず、履歴から起動し直す
        session.seen = nil
        # 経路は、常駐のあいだに変わりうる。ツールが呼ばれたときに読めるよう、ターンの前に書く
        write_route(session.route_path, route)

        relay = on_progress && @backend.progress_relay(on_progress)
        out = session.synchronize do
          session.turn(prompt, relay: relay, background: @backend.background_tracker, long_think: LongThink.new(session.long_think_path),
                               timeout: @timeout, idle_timeout: @idle_timeout, poll_interval: @poll_interval)
        end
        parsed = @backend.parse(out[:stdout], out[:stderr], nil, json_schema: json_schema)
      rescue StandardError
        pool.discard(session) # 失敗したら、そのプロセスは使い回さない
        raise
      ensure
        session.unclaim!
      end

      session.retire! if out[:context_tokens] > @max_context
      events = read_events(session.events_path, out[:events_from]) + parsed[:builtin_events]
      if session.alive?
        pool.put(session) if fresh
      else
        pool.discard(session) # 裏の作業が残った・文脈が大きくなった など。次は履歴から起動し直す
      end
      Result.new(text: parsed[:text], tool_events: events, model: model, structured: parsed[:structured],
                 followups: parsed[:followups] || [], session_key: session.alive? ? key : nil)
    end

    # 常駐の claude の鍵。起動時に固定される値はすべて入れる（変わったら、別のプロセスで履歴から起動し直す）
    # 経路（platform・channel）は入れない。1つの会話の記録に1本の claude で、経路は毎ターン伝える（ConversationRoute）
    def persistent_key(record_id, character, scene, model, system_prompt, json_schema, builtin)
      fingerprint = Digest::SHA256.hexdigest([
        system_prompt, JSON.generate(json_schema), builtin.join(","), @settings.to_s, settings_content, @work_dir.to_s,
        @backend.command, @backend.max_turns
      ].join("\u0000"))[0, 16]
      [ "r#{record_id}", "c#{character.id}", scene, model, fingerprint ].join("|")
    end

    # 権限の設定ファイルの中身（書き換えたら、別のプロセスで起動し直す）
    def settings_content
      @settings && File.exist?(@settings) ? File.read(@settings) : ""
    end

    def spawn_persistent(key, record_id, system_prompt, model, character, scene, json_schema, builtin)
      dir = Dir.mktmpdir("memoria-claude-persistent")
      route_path = File.join(dir, "route.json")
      write_route(route_path, ConversationRoute.new)
      events_path = File.join(dir, "tool_events.jsonl")
      long_think = LongThink.new(File.join(dir, "long_think.json"))
      work_dir = @work_dir || File.join(dir, "work").tap { |path| Dir.mkdir(path) }
      tools_path = write_tool_list(dir, character, scene, nil, long_think, record_id, route_path)
      config = mcp_config(character, scene, nil, nil, events_path, long_think, nil, tools_path, record_id, route_path)
      cmd = @backend.command_line(dir: dir, system_prompt: system_prompt, model: model, mcp_config: config,
                                  builtin: builtin, json_schema: json_schema, persistent: true)
      PersistentClaude::Session.new(key: key, record_id: record_id, cmd: cmd, env: { **@backend.env }, work_dir: work_dir, dir: dir,
                                    events_path: events_path, long_think_path: long_think.path,
                                    character_id: character.id, route_path: route_path)
    rescue StandardError
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
      raise
    end

    # ツールの一覧を、Rails が読み込み済みのここで作ってファイルに書く。bin/memoria_mcp はこれがあれば、
    # Rails の読み込み（約2.4秒）を最初のツール呼び出しまで遅らせる（lib/lazy_mcp.rb）。
    # 会話の場面だけ（思考ループは、ツールを使うのが普通なので対象にしない）。作れなければ nil（従来どおり最初に読み込む）
    # 書きかけを MCP が読まないよう、別のファイルに書いてから置き換える
    def write_route(path, route)
      File.write("#{path}.tmp", ConversationRoute.dump(route))
      File.rename("#{path}.tmp", path)
    end

    def write_tool_list(dir, character, scene, platform, long_think, record_id = nil, route_path = nil)
      return nil unless @lazy_mcp && scene.to_s == "chat"

      provider = ToolProvider.build(character: character, scene: scene, platform: platform, long_think_path: long_think.path, record_id: record_id, route_path: route_path)
      tools = provider.tools.map { |tool| MemoriaServer::Plugin::ToolSchema.gemini_to_json_schema(tool) }
      path = File.join(dir, "tools.json")
      File.write(path, JSON.generate(tools))
      path
    rescue StandardError => e
      Rails.logger.warn("[ClaudeCli::Runner] could not write the tool list, loading Rails eagerly: #{e.class}: #{e.message}")
      nil
    end

    def mcp_config(character, scene, platform, trigger_type, events_path, long_think, usage_context = nil, tools_path = nil, record_id = nil, route_path = nil)
      args = ["--character", character.id.to_s, "--scene", scene.to_s]
      args += ["--record-id", record_id.to_s] if record_id
      args += ["--trigger", trigger_type] if trigger_type
      args += ["--platform", platform.to_s] if platform
      env = { "MEMORIA_MCP_EVENTS" => events_path, "MEMORIA_MCP_LONG_THINK" => long_think.path, "RAILS_ENV" => Rails.env.to_s }
      env["MEMORIA_MCP_CONTEXT"] = JSON.generate(usage_context) if usage_context.present?
      # MCP プロセスの中（talk_to など）で、別の常駐 claude が立たないように
      env["CLAUDE_CLI_PERSISTENT"] = "0"
      env["MEMORIA_MCP_TOOLS"] = tools_path if tools_path
      env["MEMORIA_MCP_ROUTE"] = route_path if route_path
      {
        mcpServers: {
          memoria: {
            command: @mcp_command,
            args: args,
            env: env,
          },
        },
      }
    end

    def tool_list(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    # プロンプトは長くなるので標準入力で渡す。出力がとぎれたとき（長考の宣言中を除く）と、経過時間の上限を
    # 超えたときは、プロセスグループごと止める（コマンドが起動した MCP サーバも残さない）
    def execute(cmd, prompt, work_dir, relay = nil, long_think: nil, background: nil)
      # Brakeman は第1引数がハッシュのリテラルでないとコマンド文字列とみなすので、環境変数はリテラルに展開して渡す
      Open3.popen3({ **@backend.env }, *cmd, chdir: work_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        # ロケールに関係なく UTF-8 として読み書きする（LANG のない環境では ASCII として扱われ、日本語で壊れる）
        [stdin, stdout, stderr].each { |io| io.set_encoding(Encoding::UTF_8) }
        activity = Activity.new
        readers = []
        begin
          readers << Thread.new do
            out = +""
            stdout.each_line do |line|
              activity.touch
              out << line
              relay&.feed(line)
              background&.feed(line)
            end
            out
          end
          readers << Thread.new { stderr.read }
          stdin.write(prompt)
          stdin.close

          # 答えのあとに経過時間の上限が来たら、残った作業を止めて、そこまでの出力（答え）を読む
          kill_group(wait_thr) if watch(wait_thr, activity, relay, long_think, background) == :answered_timeout
          [readers[0].value, readers[1].value, wait_thr.value]
        ensure
          # 止めたとき・例外のとき: 残ったプロセスと読み取りのスレッドを片づける
          if wait_thr.alive?
            kill_group(wait_thr)
            readers.each { |t| t.join(1) || t.kill }
          end
        end
      end
    rescue Errno::ENOENT
      raise Error, "#{@backend.command} コマンドが見つかりません"
    end

    # 終わるまで見張る。止めるべきときは Error を上げる（プロセスは execute の ensure で止める）。
    # 答えが出たあとに止めることになったときは :answered_timeout を返す
    def watch(wait_thr, activity, relay, long_think, background = nil)
      started = monotonic_now
      announced = nil
      announced_tasks = nil
      until wait_thr.join(@poll_interval)
        declaration = long_think&.read
        if declaration && declaration != announced
          announced = declaration
          relay&.notify("長考中（〜#{declaration.minutes}分：#{declaration.reason}）")
        end

        waiting = background&.waiting_tasks || []
        if waiting.any? && waiting != announced_tasks
          announced_tasks = waiting
          relay&.notify("裏の作業が終わるのを待ってる（#{waiting.join("、")}）")
        end

        if monotonic_now - started > @timeout
          return :answered_timeout if background&.answered?

          raise Error, "#{duration_text(@timeout)}たっても終わらなかったので止めました"
        end
        next if declaration && Time.now < declaration.until_time
        next if waiting.any?

        idle = activity.idle_seconds
        # 長考の期限が過ぎたばかりなら、そこから数え直す（期限の直後に止めない）
        idle = [idle, Time.now - declaration.until_time].min if declaration
        next unless idle > @idle_timeout
        return :answered_timeout if background&.answered?

        raise Error, "#{duration_text(@idle_timeout)}出力がなかったので止めました"
      end
    end

    def duration_text(seconds)
      return "#{seconds / 3600}時間" if seconds >= 3600 && (seconds % 3600).zero?
      return "#{seconds / 60}分" if seconds >= 60 && (seconds % 60).zero?

      "#{seconds}秒"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def kill_group(wait_thr)
      Process.kill("TERM", -wait_thr.pid)
      wait_thr.join(2)
      Process.kill("KILL", -wait_thr.pid)
    rescue Errno::ESRCH
      nil
    end

    # 最後に出力があった時刻（読み取りのスレッドが書き、見張る側が読む）
    class Activity
      def initialize
        @mutex = Mutex.new
        @last = now
      end

      def touch
        @mutex.synchronize { @last = now }
      end

      def idle_seconds
        now - @mutex.synchronize { @last }
      end

      private

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # @param from [Integer] この位置（バイト）から読む（常駐の claude は、記録のファイルをターンをまたいで使う）
    def read_events(path, from = 0)
      return [] unless File.exist?(path)

      File.open(path, "r:utf-8") { |file| file.seek(from) && file.read }.to_s.lines.filter_map do |line|
        event = JSON.parse(line)
        {
          name: event["name"].to_s,
          args: event["args"] || {},
          result: event["result"].is_a?(Hash) ? event["result"].deep_symbolize_keys : { response: event["result"] },
        }
      rescue JSON::ParserError
        nil
      end
    end
  end
end
