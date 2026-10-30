require "net/http"
require "json"
require "uri"

module MemoriaServer
  # Discord の bot が、サーバーに返答を頼む側（HTTP クライアント）。判断は DiscordProtocol に任せ、通信だけを持つ。
  #
  # 契約:
  # - reply は、message イベントのテキストを、出た順にブロックへ渡す
  # - 事後条件: done イベントを受け取ったときだけ、正常に戻る
  # - Unavailable: サーバーに接続できなかった（何も頼めていない。呼び出し側は、定型文を返してよい）
  # - Rejected: サーバーが断った（HTTP のエラー）か、error イベントを返した（kind: busy / failed）
  # - Interrupted: 返答が始まったあとで、done も error もなく切れた、または ping も含めて何も来ない時間が続いた。
  #   サーバーは返答を会話の記録に残している可能性があるので、再送してはならない
  # - 最後の返答（last: true）を渡したあとで切れたときは、Interrupted にしない（返答はもう届いている）
  # - 再送しない（同じ発言が二重に記録されないように）
  class DiscordClient
    class Unavailable < StandardError; end
    class Interrupted < StandardError; end

    class Rejected < StandardError
      attr_reader :kind

      def initialize(kind, message)
        @kind = kind
        super(message)
      end
    end

    # ping は15秒おき。その3倍まで何も来なければ、切れたものとみなす
    DEFAULT_READ_TIMEOUT = 45

    # 純粋関数: bot が Discord に返す、失敗の文
    def self.failure_text(exception)
      case exception
      when Unavailable then "⚠️ memoria: いまは返答できません（サーバーに接続できませんでした）"
      when Interrupted then "⚠️ memoria: 返答が途中で切れました。返答は記録されているかもしれません"
      when Rejected
        exception.kind == "busy" ? "⚠️ memoria: 前の返答がまだ終わっていません。少し待ってから、もう一度話しかけてください" : "⚠️ memoria: 返答できませんでした（#{exception.message}）"
      else "⚠️ memoria: 返答できませんでした（#{exception.class}: #{exception.message.to_s[0, 200]}）"
      end
    end

    def initialize(base_url:, token:, read_timeout: DEFAULT_READ_TIMEOUT, open_timeout: 5)
      @uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "api/v1/discord/reply")
      @token = token
      @read_timeout = read_timeout
      @open_timeout = open_timeout
    end

    # @yield [String, Boolean] Discord に送る1通と、それが最後の返答か
    def reply(channel_id:, channel_name:, author_id:, text:, &block)
      parser = DiscordProtocol::Parser.new
      finished = false
      delivered_last = false
      started = false
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.start do |connection|
        connection.request(build_request(channel_id, channel_name, author_id, text)) do |response|
          raise rejection_for(response) unless response.is_a?(Net::HTTPSuccess)

          started = true
          response.read_body do |chunk|
            parser.feed(chunk).each do |event|
              delivered_last = true if event[:event] == "message" && event[:data]["last"] == true
              finished = true if handle(event, &block)
            end
          end
        end
      end
      raise Interrupted, "done がないまま切れました" unless finished || delivered_last
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout => e
      raise(started ? Interrupted : Unavailable, e.message) unless delivered_last
    rescue Net::ReadTimeout, EOFError, IOError => e
      raise Interrupted, e.message unless delivered_last
    end

    private

    # @return [Boolean] 終わりの印（done）か
    def handle(event)
      case event[:event]
      when "message" then yield(event[:data]["text"].to_s, event[:data]["last"] == true)
      when "done" then return true
      when "error" then raise Rejected.new(event[:data]["kind"].to_s, event[:data]["message"].to_s)
      end
      false
    end

    def build_request(channel_id, channel_name, author_id, text)
      Net::HTTP::Post.new(@uri).tap do |request|
        request["Authorization"] = "Bearer #{@token}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "text/event-stream"
        request.body = JSON.generate(channel_id: channel_id.to_s, channel_name: channel_name.to_s, author_id: author_id.to_s, text: text)
      end
    end

    def rejection_for(response)
      Rejected.new("http_#{response.code}", "サーバーが断りました（HTTP #{response.code}）")
    end
  end
end
