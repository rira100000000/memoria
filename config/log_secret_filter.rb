# ログに書く文から、秘密（API キーなど）を伏せる。
#
# 外部 API の失敗メッセージには、キーを含む URL がそのまま入ることがある（例: Gemini の `?key=...`）。
# ログのファイルは平文で残るので、書き出す直前に伏せる。config/application.rb の log_formatter に使う。
# 読み込みはログの初期化より前なので、autoload の対象外の config/ に置いている。
module LogSecretFilter
  MASK = "[FILTERED]".freeze

  PATTERNS = [
    /(?<=[?&]key=)[A-Za-z0-9._~%-]{16,}/,     # URL のクエリの key=
    /\bmsdk_[A-Za-z0-9_-]{16,}/,              # memoria のデバイスキー
    /(?<=Bearer )[A-Za-z0-9._~+\/=-]{16,}/,   # Authorization ヘッダの値
    /\bAIza[0-9A-Za-z_-]{30,}/               # Google の API キー
  ].freeze

  def self.mask(text)
    PATTERNS.reduce(text) { |masked, pattern| masked.gsub(pattern, MASK) }
  end

  # 書き出す前に伏せる書式。元の書式（既定は Rails の SimpleFormatter）の出力はそのまま
  class Formatter
    def initialize(base = ActiveSupport::Logger::SimpleFormatter.new)
      @base = base
    end

    def call(severity, timestamp, progname, message)
      @base.call(severity, timestamp, progname, LogSecretFilter.mask(message.is_a?(String) ? message : message.inspect))
    end
  end
end
