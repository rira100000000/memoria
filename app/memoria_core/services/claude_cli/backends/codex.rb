module ClaudeCli
  module Backends
    # codex exec（Codex CLI の非対話実行）。ClaudeCli::Runner が使う。
    #
    # claude -p との対応（codex-cli 0.164 で確かめたもの。詳しくは docs/CLAUDE_CLI_BACKEND.md）:
    # - システムプロンプト: ファイルに書いて model_instructions_file で渡す（Codex の既定の指示と置き換わる）
    # - 出力: --json の JSON Lines（thread.started / item.started / item.completed / turn.completed / turn.failed）
    # - MCP: -c mcp_servers.memoria.* で渡す。承認なしで呼べるように default_tools_approval_mode="approve"。
    #   MCP サーバには環境変数が引き継がれないので、名前を env_vars で並べて引き継がせる
    # - 構造化出力: スキーマをファイルに書いて --output-schema で渡す。OpenAI の strict な形に直す
    #   （すべての項目を required にし、省略できる項目は null を許す。additionalProperties: false）
    # - 非対話: approval_policy="never" とサンドボックス（--sandbox）で決める
    # - ターン数の上限: 相当するものがない（止めるのは出力のとぎれと経過時間の上限だけ）
    # - 利用者の設定（$CODEX_HOME/config.toml）は読まない（--ignore-user-config）。ただし $CODEX_HOME/AGENTS.md や
    #   スキルは読まれるので、memoria 専用の CODEX_HOME（CODEX_CLI_HOME）を使うこと
    class Codex
      LABEL = "codex exec"
      DEFAULT_SANDBOX = "workspace-write"
      # キャラクターに全部のツールを使わせない（"default" 以外の）ときに止める機能
      RESTRICTED_FEATURES = %w[shell_tool unified_exec image_generation browser_use computer_use].freeze
      # ツールを使った記録に残す項目（mcp_tool_call は MCP サーバが記録する）
      TOOL_ITEM_TYPES = %w[mcp_tool_call web_search command_execution file_change].freeze
      BUILTIN_RESULT_CHARS = 1000
      MCP_STARTUP_TIMEOUT = 120
      # システムプロンプトを置き換えると、Codex の既定の指示にあるツールの探し方が抜ける。
      # memoria のツールは exec ツールの中から呼ぶ形で出てくることがあるので、その呼び方だけ足す
      TOOL_GUIDE = <<~TEXT.freeze

        # ツールの呼び出し方
        memoria のツール（名前が mcp__memoria__ で始まるもの）は、直接呼べないときは exec ツールの JavaScript から
        `await tools.mcp__memoria__<ツール名>({...})` で呼べる。どんなツールがあるかは ALL_TOOLS を名前や説明で絞って調べる。
      TEXT

      attr_reader :command

      # @param home [String, nil] CODEX_HOME（認証と、セッションの記録の置き場所）。nil なら codex の既定（~/.codex）
      # @param sandbox [String] キャラクターに全部のツールを使わせるときのサンドボックス
      # @param tool_timeout [Integer] MCP のツール1回の時間の上限（秒）
      def initialize(command:, home: nil, sandbox: DEFAULT_SANDBOX, tool_timeout: 600)
        @command = command
        @home = home
        @sandbox = sandbox.presence || DEFAULT_SANDBOX
        @tool_timeout = tool_timeout
      end

      def label
        LABEL
      end

      # codex は node のスクリプトなので、パスで指定したときは、そのディレクトリ（nvm などでは node も同じ場所にある）を
      # PATH の前に足す
      def env
        env = {}
        env["CODEX_HOME"] = @home if @home
        if @command.include?("/")
          env["PATH"] = [File.dirname(File.expand_path(@command)), ENV["PATH"]].compact.join(File::PATH_SEPARATOR)
        end
        env
      end

      # @param model [String] "モデル名" か "モデル名:推論の強さ"（例: "gpt-6.1-sol:high"）
      def command_line(dir:, system_prompt:, model:, mcp_config:, builtin:, json_schema: nil)
        instructions_path = File.join(dir, "instructions.md")
        File.write(instructions_path, mcp_config ? system_prompt + TOOL_GUIDE : system_prompt)

        slug, effort = model.to_s.split(":", 2)
        full = builtin == ["default"]
        web = full || builtin.intersect?(%w[WebSearch WebFetch])

        cmd = [@command, "exec", "--json", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check"]
        cmd += ["--model", slug] if slug.present?
        cmd += ["-c", "model_reasoning_effort=#{toml(effort)}"] if effort.present?
        cmd += ["--sandbox", full ? @sandbox : "read-only", "-c", "approval_policy=#{toml("never")}"]
        cmd += [
          "-c", "model_instructions_file=#{toml(instructions_path)}",
          # 作業ディレクトリの AGENTS.md とスキルの案内を入れない
          "-c", "project_doc_max_bytes=0",
          "-c", "skills.include_instructions=false",
          "-c", "web_search=#{toml(web ? "live" : "disabled")}"
        ]
        RESTRICTED_FEATURES.each { |feature| cmd += ["--disable", feature] } unless full
        cmd += mcp_options(mcp_config) if mcp_config
        if json_schema
          schema_path = File.join(dir, "output_schema.json")
          File.write(schema_path, JSON.generate(self.class.strict_schema(json_schema)))
          cmd += ["--output-schema", schema_path]
        end
        # プロンプトは標準入力から読ませる
        cmd << "-"
      end

      def progress_relay(callback)
        ProgressRelay.new(callback)
      end

      # @return [Hash] text: 最終応答、structured: json_schema の形の答え、builtin_events: 組み込みツールの記録
      def parse(stdout, stderr, status, json_schema: nil)
        events = parse_stream(stdout)
        failed = events.reverse.find { |e| e["type"] == "turn.failed" }
        raise Error, error_message(failed.dig("error", "message")).truncate(300) if failed

        unless events.any? { |e| e["type"] == "turn.completed" }
          error = events.reverse.find { |e| e["type"] == "error" }
          detail = (error && error_message(error["message"])).presence || stderr.to_s.strip.presence ||
                   stdout.to_s.strip.presence || "出力なし"
          raise Error, "終了コード #{status&.exitstatus}: #{detail.truncate(300)}"
        end

        items = events.filter_map { |e| e["item"] if e["type"] == "item.completed" && e["item"].is_a?(Hash) }
        text = items.reverse.find { |item| item["type"] == "agent_message" }&.dig("text").to_s
        { text: text, structured: json_schema ? structured_answer(text) : nil, builtin_events: builtin_events(items) }
      end

      # OpenAI の構造化出力（strict）が受け付ける形に直す。省略できる項目は null を許して required に入れる
      def self.strict_schema(schema)
        schema = schema.deep_stringify_keys
        case schema["type"]
        when "object"
          properties = schema["properties"] || {}
          required = Array(schema["required"])
          schema.merge(
            "properties" => properties.to_h { |name, prop|
              prop = strict_schema(prop)
              [name, required.include?(name) ? prop : nullable(prop)]
            },
            "required" => properties.keys,
            "additionalProperties" => false
          )
        when "array"
          schema["items"] ? schema.merge("items" => strict_schema(schema["items"])) : schema
        else
          schema
        end
      end

      def self.nullable(schema)
        types = Array(schema["type"])
        return schema if types.empty? || types.include?("null")

        schema = schema.merge("type" => types + ["null"])
        schema["enum"] += [nil] if schema["enum"]
        schema
      end

      # --json の出力のうち、ツールを使う前に書いた文を途中経過として渡す
      class ProgressRelay < ClaudeCli::ProgressRelay
        private

        def feed_line(line)
          return unless line.strip.start_with?("{")

          event = JSON.parse(line)
          item = event["item"]
          return unless item.is_a?(Hash)

          if event["type"] == "item.completed" && item["type"] == "agent_message" && item["text"].to_s.strip.present?
            @pending << item["text"].strip
          elsif TOOL_ITEM_TYPES.include?(item["type"])
            flush
          end
        rescue JSON::ParserError
          nil
        end
      end

      private

      # -c の値は TOML として読まれる。文字列・数・文字列の配列は JSON の書き方がそのまま使える
      def toml(value)
        JSON.generate(value)
      end

      def toml_table(hash)
        "{" + hash.map { |key, value| "#{toml(key.to_s)} = #{toml(value.to_s)}" }.join(", ") + "}"
      end

      def mcp_options(mcp_config)
        mcp_config.deep_stringify_keys.fetch("mcpServers").flat_map do |name, server|
          env = server["env"] || {}
          prefix = "mcp_servers.#{name}"
          [
            "-c", "#{prefix}.command=#{toml(server["command"])}",
            "-c", "#{prefix}.args=#{toml(Array(server["args"]).map(&:to_s))}",
            "-c", "#{prefix}.env=#{toml_table(env)}",
            # claude -p と同じく、memoria の環境変数（API キーなど）を MCP サーバに引き継ぐ。値は渡さず名前だけ並べる
            "-c", "#{prefix}.env_vars=#{toml(ENV.keys - env.keys)}",
            "-c", "#{prefix}.default_tools_approval_mode=#{toml("approve")}",
            "-c", "#{prefix}.startup_timeout_sec=#{MCP_STARTUP_TIMEOUT}",
            "-c", "#{prefix}.tool_timeout_sec=#{@tool_timeout}"
          ]
        end
      end

      def parse_stream(stdout)
        stdout.to_s.each_line.filter_map do |line|
          JSON.parse(line) if line.strip.start_with?("{")
        rescue JSON::ParserError
          nil
        end
      end

      # API のエラーは本文が JSON のことがある
      def error_message(message)
        parsed = JSON.parse(message.to_s)
        (parsed.is_a?(Hash) && parsed.dig("error", "message")) || message.to_s
      rescue JSON::ParserError
        message.to_s
      end

      # 省略できる項目は null で返ってくるので、claude -p のときと同じく項目ごと除く
      def structured_answer(text)
        answer = JSON.parse(text)
        answer.is_a?(Hash) ? answer.compact : nil
      rescue JSON::ParserError
        nil
      end

      # 組み込みツール（Web検索・コマンドの実行・ファイルの変更）を、MCP のツールと同じ形の記録にする
      def builtin_events(items)
        items.filter_map do |item|
          case item["type"]
          when "web_search" then web_search_event(item)
          when "command_execution"
            event("shell", { "command" => item["command"].to_s }, item["aggregated_output"])
          when "file_change"
            paths = Array(item["changes"]).filter_map { |c| c["path"] if c.is_a?(Hash) }
            event("file_change", { "path" => paths.join(" ") }, Array(item["changes"]).to_json) if paths.any?
          end
        end
      end

      def web_search_event(item)
        query = item["query"].presence || item.dig("action", "query").presence
        url = item.dig("action", "url").presence
        return unless query || url

        answer = Array(item["results"]).filter_map { |r|
          [r["title"], r["url"], r["snippet"]].compact.join("\n") if r.is_a?(Hash)
        }.join("\n\n")
        query ? event("web_search", { "query" => query }, answer, "WebSearch") : event("web_fetch", { "url" => url }, answer, "WebFetch")
      end

      def event(name, args, answer, label = name)
        result = { answer: answer.to_s.truncate(BUILTIN_RESULT_CHARS) }
        result[:log] = ["[#{label}] #{args.values.join(" ").truncate(300)}"]
        { name: name, args: args, result: result }
      end
    end
  end
end
