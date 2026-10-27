module ClaudeCli
  # コマンドの出力を1行ずつ受け取り、ツールを使う前に書いた文を途中経過として渡す。
  # 最終応答は出力の最後から取るので、ここでは渡さない（ツールを使う前の文だけが途中経過になる）。
  # 出力の読み方はバックエンドごとに違うので、feed_line を各バックエンドで書く
  class ProgressRelay
    def initialize(callback)
      @callback = callback
      @pending = []
      @mutex = Mutex.new
    end

    def feed(line)
      @mutex.synchronize { feed_line(line) }
    end

    # 出力とは別に、知らせたいことを途中経過として渡す（長考の宣言など）
    def notify(text)
      @mutex.synchronize { deliver([text]) }
    end

    private

    def feed_line(line)
      raise NotImplementedError
    end

    def flush
      texts = @pending
      @pending = []
      deliver(texts)
    end

    def deliver(texts)
      texts.each { |text| @callback.call(text) }
    rescue => e
      Rails.logger.warn("[ClaudeCli] progress callback failed: #{e.message}")
    end
  end
end
