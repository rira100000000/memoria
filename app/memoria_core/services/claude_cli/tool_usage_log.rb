module ClaudeCli
  # MCP サーバ（McpServer）が実行したツールを、1回1行の JSON Lines で data/tool_calls/usage.jsonl に残す。
  # どのツールが・いつ・どの場面で使われたかを後から数えるためのもの（集計は bin/tool_usage）。
  # 引数や結果の本文は残さない。書き込みに失敗してもツールの実行は止めない。
  #
  # 1行の形:
  #   { "date": "2026-10-25", "at": "2026-10-25T10:41:08+09:00", "tool": "search_memory",
  #     "scene": "chat" | "thinking_loop" | "wakeup", "trigger": "user_message", "platform": "discord",
  #     "character_id": 1, "wakeup_id": 12, "purpose": "朝の挨拶", "ok": true, "ms": 123 }
  # trigger 以降は分かるときだけ入る（wakeup_id と purpose は予定から起きたときだけ）
  class ToolUsageLog
    TIME_ZONE = "Asia/Tokyo"
    PURPOSE_CHARS = 80

    def self.default_path
      Rails.root.join("data/tool_calls/usage.jsonl").to_s
    end

    # @param context [Hash] 予定から起きたときの { wakeup_id:, purpose: }（Runner の usage_context）
    def initialize(path: self.class.default_path, scene: nil, trigger: nil, platform: nil, character_id: nil, context: {})
      @path = path
      context = (context || {}).transform_keys(&:to_s)
      @fields = {
        "scene" => scene_label(scene, context),
        "trigger" => trigger.presence,
        "platform" => platform.presence,
        "character_id" => character_id,
        "wakeup_id" => context["wakeup_id"],
        "purpose" => context["purpose"].presence&.to_s&.truncate(PURPOSE_CHARS),
      }.compact
    end

    # ブロックでツールを実行し、その結果をそのまま返す。ok はブロックが返した結果で決める
    # @yieldreturn [Object] ツールの結果（Hash で :error を持てば失敗）
    def measure(tool)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      record(tool, ok: !(result.is_a?(Hash) && result.key?(:error)), ms: elapsed_ms(started))
      result
    end

    def record(tool, ok:, ms:)
      now = Time.current.in_time_zone(TIME_ZONE)
      entry = { "date" => now.to_date.iso8601, "at" => now.iso8601, "tool" => tool.to_s }.merge(@fields).merge("ok" => ok, "ms" => ms)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a", encoding: "utf-8") { |f| f.puts(JSON.generate(entry)) }
    rescue => e
      Rails.logger.warn("[ClaudeCli::ToolUsageLog] Could not record #{tool}: #{e.class}: #{e.message}")
    end

    private

    def scene_label(scene, context)
      return "wakeup" if context["wakeup_id"] || context["purpose"].present?

      scene.to_s == "thinking" ? "thinking_loop" : scene.to_s.presence
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end
