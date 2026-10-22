module ClaudeCli
  # キャラクターのツールを MCP（stdio、JSON-RPC 2.0）で公開する最小のサーバ。
  # claude -p バックエンド（ClaudeCli::Runner）が bin/memoria_mcp 経由で起動する。
  #
  # provider は次の2つに応える:
  #   tools                -> Gemini 形式のツール定義（functionDeclarations の中身）の配列
  #   call(name, args)     -> 実行結果の Hash
  # 実行したツールは events_path に JSON Lines で書き出す（呼び出し元が会話ログに使う）。
  class McpServer
    PROTOCOL_VERSION = "2025-06-18"

    def initialize(provider:, input: $stdin, output: $stdout, events_path: nil)
      @provider = provider
      @input = input
      @output = output
      @events_path = events_path
    end

    def run
      # ロケールに関係なく UTF-8 として読み書きする（claude が起動するときに LANG が渡らないことがある）
      @input.set_encoding(Encoding::UTF_8) if @input.respond_to?(:set_encoding)
      @output.set_encoding(Encoding::UTF_8) if @output.respond_to?(:set_encoding)
      @input.each_line do |line|
        next if line.strip.empty?

        response = handle(line)
        next unless response

        @output.write(JSON.generate(response) + "\n")
        @output.flush
      end
    end

    # @return [Hash, nil] 返すべき応答（通知には返さない）
    def handle(line)
      request = JSON.parse(line)
    rescue JSON::ParserError
      error_response(nil, -32700, "Parse error")
    else
      id = request["id"]
      return nil if id.nil? # 通知

      case request["method"]
      when "initialize"
        result(id, {
          protocolVersion: request.dig("params", "protocolVersion") || PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "memoria", version: "1" },
        })
      when "ping"
        result(id, {})
      when "tools/list"
        result(id, { tools: @provider.tools.map { |t| MemoriaServer::Plugin::ToolSchema.gemini_to_json_schema(t) } })
      when "tools/call"
        result(id, call_tool(request["params"] || {}))
      else
        error_response(id, -32601, "Method not found: #{request["method"]}")
      end
    end

    private

    def call_tool(params)
      name = params["name"].to_s
      args = params["arguments"] || {}
      tool_result = begin
        @provider.call(name, args)
      rescue => e
        Rails.logger.error("[McpServer] #{name} failed: #{e.class}: #{e.message}")
        { error: "ツールの実行に失敗しました（#{e.class}: #{e.message.to_s.truncate(200)}）" }
      end
      tool_result = { response: tool_result.to_s } unless tool_result.is_a?(Hash)

      record_event(name, args, tool_result)

      # :log と :participant は会話ログ用。LLM には渡さない（Gemini の場合と同じ）
      {
        content: [{ type: "text", text: JSON.generate(tool_result.except(:log, :participant)) }],
        isError: tool_result.key?(:error),
      }
    end

    def record_event(name, args, tool_result)
      return unless @events_path

      File.open(@events_path, "a", encoding: "utf-8") { |f| f.puts(JSON.generate(name: name, args: args, result: tool_result)) }
    end

    def result(id, value)
      { jsonrpc: "2.0", id: id, result: value }
    end

    def error_response(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end
