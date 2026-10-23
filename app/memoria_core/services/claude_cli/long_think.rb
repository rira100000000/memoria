module ClaudeCli
  # 長考の宣言。出力もツール呼び出しもないまま長く動く処理の前に、キャラクターが long_think ツールで宣言する。
  #
  # MCP サーバ（claude の子プロセス）が宣言をファイルに書き、ClaudeCli::Runner がそれを読んで、
  # 宣言された期限までは無応答でも止めない。ファイルの場所は実行ごとの一時ディレクトリにあり、
  # 環境変数 MEMORIA_MCP_LONG_THINK で MCP サーバに渡す。
  class LongThink
    TOOL_NAME = "long_think"
    MAX_MINUTES = 60

    DEFINITION = {
      name: TOOL_NAME,
      description: "長考モードに入る。出力もツール呼び出しもないまま10分を超えそうな処理" \
                   "（長いベンチマークや学習など）の前に呼ぶと、今から minutes 分のあいだは" \
                   "何も出力しなくても止められない。普通の作業では呼ばない。minutes の上限は#{MAX_MINUTES}分。",
      parameters: {
        type: "OBJECT",
        properties: {
          minutes: { type: "INTEGER", description: "今から何分のあいだ出力がなくても待ってほしいか（1〜#{MAX_MINUTES}）" },
          reason: { type: "STRING", description: "何をするのか（短く）" },
        },
        required: %w[minutes reason],
      },
    }.freeze

    attr_reader :path

    Declaration = Struct.new(:until_time, :minutes, :reason, keyword_init: true)

    def initialize(path)
      @path = path
    end

    # @return [Hash] ツールの結果
    def declare(minutes, reason, now: Time.now)
      minutes = Integer(minutes, exception: false) || Float(minutes, exception: false)&.ceil
      return { error: "minutes には1以上の整数を指定してください" } unless minutes && minutes >= 1

      capped = minutes > MAX_MINUTES
      minutes = MAX_MINUTES if capped
      until_time = now + minutes * 60
      reason = reason.to_s.strip

      # 読む側が書きかけを読まないように、別のファイルに書いてから置き換える
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate(until: until_time.to_f, minutes: minutes, reason: reason))
      File.rename(tmp, @path)

      message = "長考モードに入りました。#{until_time.strftime("%H:%M")}まで（#{minutes}分）は出力がなくても止められません。"
      message += "#{MAX_MINUTES}分を超える指定だったので、#{MAX_MINUTES}分にしました。" if capped
      { minutes: minutes, until: until_time.iso8601, capped: capped, message: message }
    end

    # @return [Declaration, nil] 宣言がなければ nil
    def read
      return nil unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      Declaration.new(until_time: Time.at(data["until"].to_f), minutes: data["minutes"].to_i, reason: data["reason"].to_s)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # MCP サーバに渡すツールに long_think を足す
    class Provider
      def initialize(provider, long_think)
        @provider = provider
        @long_think = long_think
      end

      def tools
        @provider.tools + [DEFINITION]
      end

      def call(name, args)
        return @long_think.declare(args["minutes"], args["reason"]) if name == TOOL_NAME

        @provider.call(name, args)
      end
    end
  end
end
