require "json"

# bin/memoria_mcp の入り口。Rails を読み込まずに MCP の初期化とツール一覧に答え、
# 最初のツール呼び出しが来たときに本体（ClaudeCli::McpServer）を起こして渡す。
#
# claude は起動時に initialize と tools/list を呼ぶ。キャラクターのツールを出す本体は Rails 全体を読み込む
# （約2.4秒）が、会話の多くの返答はツールを使わない。ツールの一覧は呼び出し側（Rails が読み込み済み）が
# 先にファイルへ書いて渡すので、ここでは読み込みを遅らせられる。
# Rails の外で動くので lib/ の autoload の対象にしない（bin から require_relative で読む）。
module LazyMcp
  PROTOCOL_VERSION = "2025-06-18".freeze

  class Frontend
    # @param tools_path [String] 呼び出し側が書いた、ツール一覧（MCP の形の配列）の JSON
    # @param boot [#call] 本体（handle(line) に応える ClaudeCli::McpServer）を作って返す
    def initialize(tools_path:, boot:, input: $stdin, output: $stdout)
      tools = JSON.parse(File.read(tools_path, encoding: "utf-8"))
      raise ArgumentError, "tools must be an array" unless tools.is_a?(Array)

      @tools = tools
      @boot = boot
      @input = input
      @output = output
      @server = nil
      @boot_error = nil
    end

    def run
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
      return @server.handle(line) if @server

      request = begin
        JSON.parse(line)
      rescue JSON::ParserError
        return error_response(nil, -32700, "Parse error")
      end
      id = request["id"]
      return nil if id.nil? # 通知

      case request["method"]
      when "initialize"
        result(id, {
          protocolVersion: request.dig("params", "protocolVersion") || PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "memoria", version: "1" },
        })
      when "ping" then result(id, {})
      when "tools/list" then result(id, { tools: @tools })
      else
        # ツールの呼び出しなど。本体を起こして、この行から任せる
        server = boot_server
        server ? server.handle(line) : error_response(id, -32603, "memoria server failed to start: #{@boot_error}")
      end
    end

    private

    # 本体を起こす。失敗したら理由を覚えて nil を返す（プロセスごと落とさず、そのツール呼び出しだけをエラーにする）
    def boot_server
      return @server if @server
      return nil if @boot_error

      @server = @boot.call
    rescue StandardError => e
      @boot_error = "#{e.class}: #{e.message}".slice(0, 200)
      warn "[LazyMcp] #{@boot_error}"
      nil
    end

    def result(id, value)
      { jsonrpc: "2.0", id: id, result: value }
    end

    def error_response(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end
