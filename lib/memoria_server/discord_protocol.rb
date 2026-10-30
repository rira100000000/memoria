require "json"

module MemoriaServer
  # Discord の bot とサーバーのあいだの、返答のやりとりの形式。すべて純粋関数（と、入力を溜めるだけのパーサー）。
  #
  # サーバーは Server-Sent Events で、次のイベントを送る:
  #   accepted {character:}   リクエストを受け付けた（最初に1回。順番待ちの前に送る）
  #   message {text:, last:}  Discord に送る1通。last は、それが最後の返答か
  #   done    {}              返答が終わった（正常な終わりの印。これがないまま切れたら、途中で切れたもの）
  #   error   {kind:, message:} 返答できなかった。kind は busy（同じキャラの別の返答が終わらない）か failed
  # 加えて、15秒おきにコメント行（": ping"）を送る。bot は、これで接続が生きているか分かる
  #
  # 契約:
  # - encode は1つの文字列を返す（1イベントを1回の write で書けるように）。decode(encode(e)) == e
  # - Parser は、チャンクの区切りがイベントの途中にあっても、同じイベントの列を返す
  # - Parser は、コメント行を捨てる
  # - split_message は、結合すると元の文になる。各片は limit 文字以下
  module DiscordProtocol
    PING = ": ping\n\n".freeze
    MESSAGE_LIMIT = 2000

    module_function

    def encode(event, data = {})
      "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
    end

    # @return [Hash] { kind:, message: } 例外を、bot に見せるエラーにする。内部の詳細は出しすぎない
    def error_for(exception)
      if exception.is_a?(MemoriaServer::Busy)
        { kind: "busy", message: "別の返答がまだ終わっていません" }
      else
        { kind: "failed", message: "#{exception.class}: #{exception.message.to_s[0, 200]}" }
      end
    end

    # Discord のメッセージ上限（2000文字）に収まるよう分ける
    def split_message(text, limit: MESSAGE_LIMIT)
      return [ text ] if text.length <= limit

      text.scan(/.{1,#{limit}}/m)
    end

    # "1,2, 3" のような環境変数の値を、ID の配列にする（空要素は捨てる）
    def parse_ids(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    # 送り手の許可。許可の一覧が空なら、全員を許可する（bot の既存の挙動と同じ）
    def allowed_user?(allowed_ids, author_id)
      ids = Array(allowed_ids).map(&:to_s)
      ids.empty? || ids.include?(author_id.to_s)
    end

    # イベントの文字列を、少しずつ受け取って、できあがったイベントを返す
    class Parser
      def initialize
        @buffer = +""
      end

      # @return [Array<Hash>] { event: String, data: Hash } の配列
      def feed(chunk)
        @buffer << chunk.to_s.gsub("\r\n", "\n")
        events = []
        while (index = @buffer.index("\n\n"))
          block = @buffer.slice!(0, index + 2)
          event = parse_block(block)
          events << event if event
        end
        events
      end

      private

      def parse_block(block)
        name = nil
        data = +""
        block.each_line do |line|
          line = line.chomp
          next if line.empty? || line.start_with?(":")

          field, value = line.split(":", 2)
          value = value.to_s.sub(/\A /, "")
          case field
          when "event" then name = value
          when "data" then data << value
          end
        end
        return nil unless name

        { event: name, data: data.empty? ? {} : JSON.parse(data) }
      rescue JSON::ParserError
        nil
      end
    end
  end
end
