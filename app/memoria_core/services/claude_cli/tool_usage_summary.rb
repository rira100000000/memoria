require "date"
require "json"

module ClaudeCli
  # ToolUsageLog が残した data/tool_calls/usage.jsonl を、ツール名ごとに数える（bin/tool_usage から使う）。
  # Rails なしでも動くようにしておく
  class ToolUsageSummary
    Row = Struct.new(:tool, :count, :failures, :total_ms, :last_at, :scenes, keyword_init: true) do
      def average_ms
        count.zero? ? 0 : (total_ms.to_f / count).round
      end
    end

    attr_reader :rows, :purposes, :entries

    # @param since [Date, nil] この日から（含む）
    # @param until_date [Date, nil] この日まで（含む）
    def self.load(path, since: nil, until_date: nil)
      lines = File.exist?(path) ? File.readlines(path, encoding: "utf-8") : []
      entries = lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      new(entries, since: since, until_date: until_date)
    end

    def initialize(entries, since: nil, until_date: nil)
      @since = since
      @until_date = until_date
      @entries = entries.select { |e| e.is_a?(Hash) && e["tool"] && within?(e) }
      @rows = build_rows
      @purposes = @entries.select { |e| e["scene"] == "wakeup" }.group_by { |e| e["purpose"] || "(目的なし)" }
        .transform_values(&:size).sort_by { |purpose, count| [-count, purpose] }
    end

    def scenes
      @entries.map { |e| scene_of(e) }.uniq.sort
    end

    def to_text
      return "記録がありません（#{period_text}）" if @entries.empty?

      scene_names = scenes
      header = ["ツール", "回数", "失敗", "平均ms", "最終使用", *scene_names]
      table = @rows.map { |r|
        [r.tool, r.count, r.failures, r.average_ms, r.last_at.to_s[0, 16].tr("T", " "), *scene_names.map { |s| r.scenes.fetch(s, 0) }].map(&:to_s)
      }
      widths = header.each_index.map { |i| ([header[i]] + table.map { |row| row[i] }).map { |c| display_width(c) }.max }

      lines = ["期間: #{period_text}（#{@entries.size}回、#{@rows.size}ツール）", ""]
      lines << format_row(header, widths)
      table.each { |row| lines << format_row(row, widths) }
      if @purposes.any?
        lines << "" << "予定からの起床（purpose 別の呼び出し回数）:"
        @purposes.each { |purpose, count| lines << "  #{count.to_s.rjust(5)}  #{purpose}" }
      end
      lines.join("\n")
    end

    private

    def within?(entry)
      date = Date.parse(entry["date"] || entry["at"].to_s[0, 10])
      (@since.nil? || date >= @since) && (@until_date.nil? || date <= @until_date)
    rescue ArgumentError, TypeError
      false
    end

    def build_rows
      @entries.group_by { |e| e["tool"] }.map { |tool, list|
        Row.new(
          tool: tool,
          count: list.size,
          failures: list.count { |e| e["ok"] == false },
          total_ms: list.sum { |e| e["ms"].to_i },
          last_at: list.map { |e| e["at"].to_s }.max,
          scenes: list.group_by { |e| scene_of(e) }.transform_values(&:size)
        )
      }.sort_by { |r| [-r.count, r.tool] }
    end

    def scene_of(entry)
      entry["scene"] || "unknown"
    end

    def period_text
      from = @since&.iso8601 || @entries.map { |e| e["date"] }.compact.min || "最初"
      to = @until_date&.iso8601 || @entries.map { |e| e["date"] }.compact.max || "最後"
      "#{from} 〜 #{to}"
    end

    def format_row(cells, widths)
      cells.each_with_index.map { |cell, i|
        pad = " " * (widths[i] - display_width(cell))
        i.zero? ? cell + pad : pad + cell
      }.join("  ").rstrip
    end

    # 全角文字を2桁として数える（日本語の場面名・目的を揃えるため）
    def display_width(text)
      text.each_char.sum { |c| c.bytesize > 1 ? 2 : 1 }
    end
  end
end
