module MemoriaCore
  # Stage 1: ルールベースのTPNスキャン（LLM不要）
  # 重要度が高い・長期間更新なし・未解決フラグのあるトピックを抽出
  class TopicScanner
    # スキャン結果を返す閾値
    STALE_DAYS = 14        # この日数以上更新なしのTPNは候補
    HIGH_SIGNIFICANCE_KEYWORDS = %w[重要 大切 好き 嫌い 目標 夢 悩み 不安 約束].freeze

    def initialize(vault)
      @vault = vault
      @tpn_store = TpnStore.new(vault)
    end

    # TPNをスキャンして思考対象トピックを返す
    # @return [Array<Hash>] [{ tag:, reason:, score:, updated_date: }, ...]
    def scan
      candidates = []

      @tpn_store.list.each do |path|
        content = @vault.read(path)
        next unless content

        fm, body = Frontmatter.parse(content)
        next unless fm

        tag = fm["tag_name"] || File.basename(path, ".md").sub(/\ATPN-/, "")
        score = 0
        reasons = []

        # 1. 長期間未更新チェック
        days_since = days_since_update(fm["updated_date"])
        if days_since && days_since > STALE_DAYS
          score += [days_since / 7, 5].min  # 週ごとに+1, 最大5
          reasons << "#{days_since.to_i}日間更新なし"
        end

        # 2. 重要度チェック（master_significanceの内容）
        significance = fm["master_significance"].to_s
        if HIGH_SIGNIFICANCE_KEYWORDS.any? { |kw| significance.include?(kw) || body.to_s.include?(kw) }
          score += 2
          reasons << "重要トピック"
        end

        # 3. 未解決action_itemsチェック（関連SNから）
        if has_unresolved_items?(fm)
          score += 3
          reasons << "未解決アイテムあり"
        end

        # 4. ユーザー感情が強いトピック
        sentiment = fm.dig("user_sentiment", "overall").to_s
        if %w[Positive Negative Strong].any? { |s| sentiment.include?(s) }
          score += 1
          reasons << "感情的重要性"
        end

        next if score < 2  # 閾値未満はスキップ

        candidates << {
          tag: tag,
          reasons: reasons,
          score: score,
          updated_date: fm["updated_date"],
          path: path,
        }
      end

      candidates.sort_by { |c| -c[:score] }
    end

    private

    def days_since_update(date_val)
      return nil unless date_val
      parsed = parse_time(date_val)
      return nil unless parsed
      (Time.now - parsed) / 86400.0
    end

    def parse_time(val)
      return val if val.is_a?(Time)
      return val.to_time if val.is_a?(Date)
      match = val.to_s.match(/(\d{4})-(\d{2})-(\d{2})\s*(\d{2})?:?(\d{2})?/)
      return nil unless match
      Time.new(match[1].to_i, match[2].to_i, match[3].to_i, (match[4] || 0).to_i, (match[5] || 0).to_i)
    rescue ArgumentError
      nil
    end

    def has_unresolved_items?(fm)
      action_items = Array(fm["action_items"])
      action_items.any? { |item| item.to_s.strip.present? }
    end
  end
end
