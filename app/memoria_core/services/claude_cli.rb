# claude -p（Claude Code のヘッドレス実行）で、キャラクターの会話・思考と軽い作業を動かすバックエンド。
#
# 既定は Gemini。MEMORIA_AGENT_BACKEND=claude_cli のときだけ使う。
# LLM_CLI_BACKEND=codex にすると、claude -p の代わりに codex exec（Codex CLI）で動かす（未設定なら claude）。
# claude はこのマシンにインストール済みのものをそのまま呼ぶ。認証（サブスクリプションか
# API キーか）は利用者の claude の設定に任せ、memoria は認証情報に触れない。
# サブスクリプションで使う場合の扱いは Anthropic の規約に従うこと（docs/CLAUDE_CLI_BACKEND.md）。
#
# - 会話と思考ループ（ツールを使うループ）: CLAUDE_CLI_MODEL（込み入った会話では CLAUDE_CLI_DEEP_MODEL）
# - 振り返り・タグ付け・睡眠フェーズ・ペットの返答などの軽い作業（LlmClient#generate）: CLAUDE_CLI_LIGHT_MODEL
# - codex のときは CODEX_CLI_MODEL / CODEX_CLI_DEEP_MODEL / CODEX_CLI_LIGHT_MODEL（"モデル名:推論の強さ" の形でも書ける）
# - 埋め込み・Web検索・音声の書き起こしは Gemini のまま（Claude に同じ機能がないため）
#
# claude -p が使えないときに Gemini で代わりに動くことはしない。会話では返答できなかったと返し、
# 思考ループでは連絡手段に知らせる。
module ClaudeCli
  # claude -p（codex exec）が使えなかった（異常終了・タイムアウト・利用枠切れなど）
  class Error < StandardError; end

  FAILURE_NOTICE_INTERVAL = 1.hour
  BACKENDS = %w[claude codex].freeze
  CODEX_DEFAULT_MODEL = "gpt-6.1-sol:medium"
  CODEX_DEFAULT_DEEP_MODEL = "gpt-6.1-sol:high"
  CODEX_DEFAULT_LIGHT_MODEL = "gpt-6-luna:low"
  @last_notice_at = {}
  @notice_mutex = Mutex.new

  class << self
    def enabled?
      ENV["MEMORIA_AGENT_BACKEND"] == "claude_cli"
    end

    # 実行に使うコマンド: "claude"（claude -p）か "codex"（codex exec）
    def backend
      name = ENV["LLM_CLI_BACKEND"].to_s.strip.downcase
      BACKENDS.include?(name) ? name : "claude"
    end

    def codex?
      backend == "codex"
    end

    # 知らせる文などで使う、実行に使うものの名前
    def label
      codex? ? Backends::Codex::LABEL : Backends::Claude::LABEL
    end

    # 普段のモデル。deep: true は開発の相談や壁打ちのような込み入った会話で使うモデル
    def model(deep: false)
      if codex?
        return deep ? ENV.fetch("CODEX_CLI_DEEP_MODEL", CODEX_DEFAULT_DEEP_MODEL) : ENV.fetch("CODEX_CLI_MODEL", CODEX_DEFAULT_MODEL)
      end

      deep ? ENV.fetch("CLAUDE_CLI_DEEP_MODEL", "opus") : ENV.fetch("CLAUDE_CLI_MODEL", "sonnet")
    end

    # 記憶の整理などの軽い作業で使うモデル
    def light_model
      codex? ? ENV.fetch("CODEX_CLI_LIGHT_MODEL", CODEX_DEFAULT_LIGHT_MODEL) : ENV.fetch("CLAUDE_CLI_LIGHT_MODEL", "haiku")
    end

    # 会話の途中で強いモデルに切り替えられるか（普段のモデルと別のものが設定されているか）
    def deep_model_available?
      enabled? && model(deep: true).present? && model(deep: true) != model
    end

    # 動けなかったことを連絡手段に知らせる。続けて失敗しても、知らせるのは1時間に1回まで（プロセスごとに数える）
    def notify_failure(character, error, what:)
      now = Time.current
      @notice_mutex.synchronize do
        last = @last_notice_at[character.id]
        return if last && now - last < FAILURE_NOTICE_INTERVAL

        @last_notice_at[character.id] = now
      end
      ::MessageDispatcher.dispatch(character, failure_notice(error, what: what), to: ::ChannelBinding::SYSTEM)
    rescue => e
      Rails.logger.warn("[ClaudeCli] failure notice failed: #{e.message}")
    end

    def reset_failure_notices!
      @notice_mutex.synchronize { @last_notice_at.clear }
    end

    # @param what [String] できなかったこと（例: "返答"）
    def failure_notice(error, what:)
      "⚠️ memoria: #{label} が使えなかったので、#{what}できませんでした（#{error.message.to_s.truncate(150)}）"
    end
  end
end
