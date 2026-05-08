require "net/http"
require "uri"
require "json"

module MemoriaServer
  module Adapters
    # HTTP 経由で外部アダプタ（Python / Node / Go 等で書かれた）に接続するアダプタ。
    #
    # 外部アダプタは以下の HTTP インターフェースを実装する想定：
    #
    #   POST /respond
    #     Body:     application/json — { "input": "...", "context": { ... } }
    #     Response: application/x-ndjson — 1行1チャンクの JSON
    #               { "delta": "..." }
    #               { "tool_calls": [...] }
    #               { "done": true, "metadata": { ... } }
    #
    #   POST /boundary  (オプショナル)
    #     Body:     { "character_id": 42, "reason": "..." }
    #     Response: { "ok": true, "had_active_session": true } 等
    #
    #   POST /history   (オプショナル)
    #     Body:     { "character_id": 42, "limit": 50 }
    #     Response: { "messages": [{ "role": ..., "content": ..., "at": ... }] }
    #
    # 環境変数：
    #   MS_ADAPTER_URL   外部アダプタのベースURL（例 http://localhost:8080）
    #   MS_ADAPTER_TIMEOUT  リクエストタイムアウト秒（デフォルト 120）
    class Http < MemoriaServer::Adapter
      def initialize(base_url: ENV["MS_ADAPTER_URL"], timeout: ENV.fetch("MS_ADAPTER_TIMEOUT", "120").to_i)
        raise MemoriaServer::Error, "MS_ADAPTER_URL is required for the HTTP adapter" if base_url.to_s.empty?
        @base_url = base_url.chomp("/")
        @timeout = timeout
      end

      def respond(input, context:)
        Enumerator.new do |y|
          stream_post("/respond", { input: input, context: serialize_context(context) }) do |line|
            chunk = parse_chunk(line)
            next unless chunk
            y << chunk
          end
        end
      end

      def on_boundary(character_id:, reason:)
        body = post_json("/boundary", { character_id: character_id, reason: reason })
        body
      rescue NotImplementedRemotely
        nil
      end

      def history(character_id:, limit: 50)
        body = post_json("/history", { character_id: character_id, limit: limit })
        Array(body["messages"] || body[:messages])
      rescue NotImplementedRemotely
        []
      end

      private

      class NotImplementedRemotely < StandardError; end

      def serialize_context(context)
        # Time オブジェクトは ISO8601 にしておく
        ctx = context.dup
        ctx[:last_interaction_at] = ctx[:last_interaction_at]&.iso8601
        ctx
      end

      def parse_chunk(line)
        return nil if line.strip.empty?
        json = JSON.parse(line)
        # JSON のキーを symbol に揃える（contract に従う）
        result = {}
        result[:delta] = json["delta"] if json.key?("delta")
        result[:emotion] = json["emotion"] if json.key?("emotion")
        result[:tool_calls] = json["tool_calls"] if json.key?("tool_calls")
        if json["done"]
          result[:done] = true
          result[:metadata] = json["metadata"] || {}
        end
        result.empty? ? nil : result
      rescue JSON::ParserError
        nil
      end

      def stream_post(path, payload)
        uri = URI("#{@base_url}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/x-ndjson"
        req.body = payload.to_json

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: @timeout) do |http|
          http.request(req) do |response|
            case response
            when Net::HTTPNotFound
              raise NotImplementedRemotely
            when Net::HTTPSuccess
              # ndjson を行単位でパース
              buffer = +""
              response.read_body do |chunk|
                buffer << chunk
                while (idx = buffer.index("\n"))
                  line = buffer.slice!(0..idx).chomp
                  yield line
                end
              end
              yield buffer.chomp unless buffer.empty?
            else
              raise MemoriaServer::Error, "HTTP adapter returned #{response.code}: #{response.body[0..200]}"
            end
          end
        end
      end

      def post_json(path, payload)
        uri = URI("#{@base_url}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = payload.to_json

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: @timeout) do |http|
          response = http.request(req)
          case response
          when Net::HTTPNotFound
            raise NotImplementedRemotely
          when Net::HTTPSuccess
            JSON.parse(response.body)
          else
            raise MemoriaServer::Error, "HTTP adapter returned #{response.code}: #{response.body[0..200]}"
          end
        end
      end
    end
  end
end
