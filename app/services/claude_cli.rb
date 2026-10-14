# claude -p（Claude Code のヘッドレス実行）で、キャラクターの会話と思考を動かすバックエンド。
#
# 既定は Gemini。MEMORIA_AGENT_BACKEND=claude_cli のときだけ使う。
# claude はこのマシンにインストール済みのものをそのまま呼ぶ。認証（サブスクリプションか
# API キーか）は利用者の claude の設定に任せ、memoria は認証情報に触れない。
# サブスクリプションで使う場合の扱いは Anthropic の規約に従うこと（README 参照）。
#
# claude -p に任せるのはツールを使うループ（会話と思考ループ）だけ。埋め込み・振り返り・
# ペットの返答などの軽い処理は Gemini のまま。
module ClaudeCli
  # claude -p が使えなかった（異常終了・タイムアウト・利用枠切れなど）。呼び出し側は Gemini に切り替える
  class Error < StandardError; end

  FALLBACK_NOTICE_INTERVAL = 1.hour
  @last_notice_at = {}
  @notice_mutex = Mutex.new

  class << self
    def enabled?
      ENV["MEMORIA_AGENT_BACKEND"] == "claude_cli"
    end

    # 普段のモデル。deep: true は開発の相談や壁打ちのような込み入った会話で使うモデル
    def model(deep: false)
      deep ? ENV.fetch("CLAUDE_CLI_DEEP_MODEL", "opus") : ENV.fetch("CLAUDE_CLI_MODEL", "sonnet")
    end

    # 会話の途中で強いモデルに切り替えられるか（普段のモデルと別のものが設定されているか）
    def deep_model_available?
      enabled? && model(deep: true).present? && model(deep: true) != model
    end

    # Gemini に切り替えたことを連絡手段に知らせる。思考ループが続けて失敗しても、知らせるのは1時間に1回まで
    # （プロセスごとに数える）
    def notify_fallback(character, error)
      now = Time.current
      @notice_mutex.synchronize do
        last = @last_notice_at[character.id]
        return if last && now - last < FALLBACK_NOTICE_INTERVAL

        @last_notice_at[character.id] = now
      end
      ::MessageDispatcher.dispatch(character, fallback_notice(error))
    rescue => e
      Rails.logger.warn("[ClaudeCli] fallback notice failed: #{e.message}")
    end

    def reset_fallback_notices!
      @notice_mutex.synchronize { @last_notice_at.clear }
    end

    def fallback_notice(error)
      "⚠️ memoria: claude -p が使えなかったので Gemini で動きました（#{error.message.to_s.truncate(150)}）"
    end
  end
end
