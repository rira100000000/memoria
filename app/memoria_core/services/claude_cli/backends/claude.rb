module ClaudeCli
  module Backends
    # claude -p（Claude Code のヘッドレス実行）。ClaudeCli::Runner が使う。
    #
    # 出力は stream-json で受け取る。MCP の設定はファイルにして --mcp-config で渡す。
    # 利用者の Claude Code の設定ファイル（~/.claude など）は読まない（--setting-sources ""）。
    class Claude
      LABEL = "claude -p"
      # json_schema を指定したとき、claude -p が答えを返すのに使うツール
      STRUCTURED_OUTPUT_TOOL = "StructuredOutput"
      # 組み込みツールの呼び出しを記録するときの名前（Web検索は Gemini のときと同じ名前にそろえる）
      BUILTIN_EVENT_NAMES = { "WebSearch" => "web_search", "WebFetch" => "web_fetch" }.freeze
      # 組み込みツールの入力のうち、記録に残すもの
      BUILTIN_EVENT_ARGS = %w[query url command file_path path pattern description].freeze
      BUILTIN_RESULT_CHARS = 1000

      attr_reader :command

      def initialize(command:, max_turns:, settings: nil)
        @command = command
        @max_turns = max_turns
        @settings = settings
      end

      def label
        LABEL
      end

      # コマンドに足す環境変数
      def env
        {}
      end

      # @param dir [String] 実行ごとの一時ディレクトリ（設定ファイルなどを置く）
      # @param mcp_config [Hash, nil] キャラクターのツールを出す MCP サーバの設定（Claude Code の mcpServers の形）
      # @param builtin [Array<String>] 使わせる組み込みツール（["default"] なら全部）
      def command_line(dir:, system_prompt:, model:, mcp_config:, builtin:, json_schema: nil)
        cmd = [
          @command, "-p",
          "--output-format", "stream-json", "--verbose",
          "--model", model,
          "--system-prompt", system_prompt,
          "--tools", builtin.join(","),
          "--strict-mcp-config",
          "--setting-sources", "",
          "--no-session-persistence",
          "--max-turns", @max_turns.to_s
        ]
        cmd += ["--json-schema", JSON.generate(json_schema)] if json_schema
        if mcp_config
          config_path = File.join(dir, "mcp.json")
          File.write(config_path, JSON.generate(mcp_config))
          # "default"（全部）のときの許可は設定ファイルの権限に任せ、個別に名前を挙げたものだけ許可に足す
          allowed = builtin == ["default"] ? [] : builtin
          cmd += ["--mcp-config", config_path, "--allowedTools", "mcp__memoria", *allowed]
          cmd += ["--settings", @settings] if @settings
        end
        cmd
      end

      def progress_relay(callback)
        ProgressRelay.new(callback)
      end

      # @return [Hash] text: 最終応答、structured: json_schema の形の答え、builtin_events: 組み込みツールの記録
      def parse(stdout, stderr, status, json_schema: nil)
        messages = parse_stream(stdout)
        result = answer_result(messages)
        text = final_text(result, stdout, stderr, status)
        structured = result&.dig("structured_output")
        { text: text, structured: structured.is_a?(Hash) ? structured : nil, builtin_events: builtin_events(messages) }
      end

      def background_tracker
        BackgroundTracker.new
      end

      # 答え（最初の result 行）が出たか、そのとき裏で走っている作業（run_in_background）が残っているかを見る。
      # 残っていると、claude -p はそれが終わるまで終わらない（answer_result を参照）
      class BackgroundTracker
        def initialize
          @mutex = Mutex.new
          @answered = false
          @tasks = []
        end

        def feed(line)
          return unless line.strip.start_with?("{")

          m = JSON.parse(line)
          @mutex.synchronize do
            @answered = true if m["type"] == "result"
            # 走っている作業の一覧が、変わるたびに丸ごと届く
            @tasks = Array(m["tasks"]).filter_map { |t| t["description"] if t.is_a?(Hash) } if m["type"] == "system" && m["subtype"] == "background_tasks_changed"
          end
        rescue JSON::ParserError
          nil
        end

        def answered?
          @mutex.synchronize { @answered }
        end

        # 答えのあと、終わるのを待っている作業の説明（待っていなければ空）
        def waiting_tasks
          @mutex.synchronize { @answered ? @tasks.dup : [] }
        end
      end

      # stream-json のうち、ツールを使う前に書いた文を途中経過として渡す。
      # サブエージェントの文（parent_tool_use_id があるもの）は渡さない。
      # 答え（最初の result 行）のあとに裏の作業の知らせで動いた分も渡さない（answer_result を参照）
      class ProgressRelay < ClaudeCli::ProgressRelay
        private

        def feed_line(line)
          return if @answered
          return unless line.strip.start_with?("{")

          m = JSON.parse(line)
          if m["type"] == "result"
            @answered = true
            return
          end
          return unless m["type"] == "assistant" && m["message"].is_a?(Hash) && m["parent_tool_use_id"].nil?

          Array(m["message"]["content"]).each do |c|
            next unless c.is_a?(Hash)

            if c["type"] == "text" && c["text"].to_s.strip.present?
              @pending << c["text"].strip
            elsif c["type"] == "tool_use" && c["name"] == STRUCTURED_OUTPUT_TOOL
              # 決まった形の答えを返す直前の文は途中経過ではない（答えの中身が返答になる）
              @pending = []
            elsif c["type"] == "tool_use"
              flush
            end
          end
        rescue JSON::ParserError
          nil
        end
      end

      private

      # stream-json の各行（JSON）を読む。JSON でない行は飛ばす
      def parse_stream(stdout)
        stdout.to_s.each_line.filter_map do |line|
          JSON.parse(line) if line.strip.start_with?("{")
        rescue JSON::ParserError
          nil
        end
      end

      # 答えの result 行。裏で走らせた作業（run_in_background）が答えのあとに終わると、claude -p はその知らせで
      # もう一度動いて result 行をもう1つ出す。それは答えではない（「裏の作業が終わった」という独り言）ので、
      # 最初にうまくいった result を答えにする。うまくいったものがなければ、最後の result（エラーの理由）を使う
      def answer_result(messages)
        results = messages.select { |m| m["type"] == "result" }
        results.find { |m| !m["is_error"] && m["subtype"] == "success" } || results.last
      end

      def final_text(result, stdout, stderr, status)
        unless result
          detail = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "出力なし"
          raise Error, "終了コード #{status&.exitstatus}: #{detail.truncate(300)}"
        end
        if result["is_error"] || result["subtype"] != "success"
          reason = result["result"].presence || result["subtype"] || "不明なエラー"
          raise Error, reason.to_s.truncate(300)
        end
        result["result"].to_s
      end

      # 組み込みツール（Web検索など）の呼び出しと結果を、MCP のツールと同じ形の記録にする
      def builtin_events(messages)
        calls = {}
        results = {}
        messages.each do |m|
          # message が文字列の行（システムの通知など）もある
          content = m["message"].is_a?(Hash) ? m["message"]["content"] : nil
          Array(content).each do |c|
            next unless c.is_a?(Hash)

            # mcp__ はキャラクターのツール（MCP サーバが記録する）、StructuredOutput は json_schema の答え
            if m["type"] == "assistant" && c["type"] == "tool_use" && !c["name"].to_s.start_with?("mcp__") &&
                c["name"] != STRUCTURED_OUTPUT_TOOL
              calls[c["id"]] = c
            elsif m["type"] == "user" && c["type"] == "tool_result"
              results[c["tool_use_id"]] = tool_result_text(c["content"])
            end
          end
        end

        calls.map do |id, call|
          name = BUILTIN_EVENT_NAMES.fetch(call["name"], call["name"])
          args = (call["input"] || {}).slice(*BUILTIN_EVENT_ARGS)
          result = { answer: results[id].to_s.truncate(BUILTIN_RESULT_CHARS) }
          # 何をしたか（検索語・開いた URL・実行したコマンドなど）を会話ログに残す
          result[:log] = ["[#{call["name"]}] #{args.values.join(" ").truncate(300)}"]
          { name: name, args: args, result: result }
        end
      end

      def tool_result_text(content)
        return content.to_s unless content.is_a?(Array)

        content.filter_map { |c| c["text"] if c.is_a?(Hash) }.join("\n")
      end
    end
  end
end
