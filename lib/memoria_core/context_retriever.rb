module MemoriaCore
  # セマンティック検索 + TPN/SN展開によるコンテキスト構築
  class ContextRetriever
    BASE_DECAY_RATE = 0.02
    STRONG_EMOTION_KEYWORDS = %w[
      感動 悲しみ 悲しい 怒り 怒った 達成感 興奮
      不安 喜び 嬉しい 楽しい 辛い 苦しい 驚き
      感謝 誇り 後悔 熱中 情熱 切ない 幸せ
    ].freeze
    EMOTION_BOOST_FACTOR = 1.2
    MAX_SNS_PER_TPN = 5

    # Park et al. (Generative Agents) の importance スコアを乗算ブーストとして反映する。
    # SN frontmatter の "importance" (1-10 の整数) を読み、5 を中立とした上で
    # 1 ポイント差で IMPORTANCE_BOOST_PER_POINT (10%) スコアが変動する。
    # importance 1: 0.6x / 5: 1.0x / 10: 1.5x
    IMPORTANCE_NEUTRAL = 5
    IMPORTANCE_BOOST_PER_POINT = 0.1

    def initialize(vault, embedding_store, settings = {})
      @vault = vault
      @embedding_store = embedding_store
      @settings = settings
      @tag_scores_cache = nil
    end

    # メインのコンテキスト取得メソッド
    # @return [Hash] { original_prompt:, retrieved_items:, llm_context_prompt: }
    def retrieve(user_prompt)
      result = {
        original_prompt: user_prompt,
        retrieved_items: [],
        llm_context_prompt: "記憶からの関連情報は見つかりませんでした。",
      }

      return result unless @embedding_store

      # Step 1: セマンティック検索
      semantic_items = semantic_search(user_prompt)
      return result if semantic_items.empty?

      # Step 2: TPN/SN分離
      tpn_items = semantic_items.select { |i| i[:source_type] == "TPN" }
      sn_items_from_search = semantic_items.select { |i| i[:source_type] == "SN" }

      # Step 3: TPNからSNリンクを展開
      existing_sn_names = sn_items_from_search.map { |i| i[:source_name] }.to_set
      sn_names_from_tpns = extract_sn_links_from_tpns(tpn_items)
      new_sn_names = sn_names_from_tpns.reject { |name| existing_sn_names.include?(name) }

      # Step 4: 追加SNを取得
      additional_sn_items = new_sn_names.any? ? fetch_sn_items(new_sn_names) : []

      # Step 5: 統合・重複排除
      all_items = deduplicate(tpn_items + sn_items_from_search + additional_sn_items)

      # Step 5.5: スコア調整（時間減衰 + 感情ブースト）
      apply_score_adjustments(all_items)

      result[:retrieved_items] = all_items

      # Step 6: LLM用フォーマット
      result[:llm_context_prompt] = format_context_for_llm(all_items) if all_items.any?

      result
    end

    private

    def semantic_search(user_prompt)
      query_embedding = @embedding_store.embed_query(user_prompt)
      return [] unless query_embedding

      top_k = @settings[:semantic_search_top_k] || 5
      min_sim = @settings[:semantic_search_min_similarity] || 0.3
      results = @embedding_store.find_similar(query_embedding, top_k: top_k, min_similarity: min_sim)

      results.filter_map do |r|
        entry = r[:entry]
        if entry["sourceType"] == "TPN"
          fetch_tpn_item(entry["filePath"], r[:similarity])
        elsif entry["sourceType"] == "SN"
          fetch_sn_item_from_path(entry["filePath"], r[:similarity])
        end
      end
    end

    def fetch_tpn_item(file_path, similarity)
      content = @vault.read(file_path)
      return nil unless content

      fm, body = Frontmatter.parse(content)
      return nil unless fm

      tag_name = fm["tag_name"] || File.basename(file_path, ".md").sub(/^TPN-/, "")
      snippet = ""

      # 意味記憶を抽出
      if (semantic_match = body.match(/## What it is（意味記憶）\s*(.*?)(?=\n## |$)/m))
        snippet += "[定義] #{semantic_match[1].strip}\n" unless semantic_match[1].strip.empty?
      end

      snippet += "[あなたとの関わり] #{fm['master_significance']}\n" if fm["master_significance"] && !fm["master_significance"].empty?
      snippet += "関連キーテーマ: #{Array(fm['key_themes']).join(', ')}\n" if fm["key_themes"]&.any?

      # エピソード記憶セクション
      %w[概要 これまでの主な文脈 ユーザーの意見・反応].each do |section|
        if (match = body.match(/### #{Regexp.escape(section)}\s*(.*?)(?=\n### |$)/m))
          snippet += "\n### #{section}\n#{match[1].strip}\n" unless match[1].strip.empty?
        end
      end

      {
        source_type: "TPN",
        source_name: File.basename(file_path, ".md"),
        title: "タグプロファイル: #{tag_name}",
        date: fm["updated_date"] || fm["created_date"],
        content_snippet: snippet.strip.empty? ? "関連情報なし" : snippet.strip,
        relevance: similarity * 100,
        confidence: fm["confidence"],
      }
    end

    def fetch_sn_item_from_path(file_path, similarity)
      content = @vault.read(file_path)
      return nil unless content

      fm, body = Frontmatter.parse(content)
      return nil unless fm

      snippet = build_sn_snippet(fm, body)

      {
        source_type: "SN",
        source_name: File.basename(file_path, ".md"),
        title: fm["title"],
        date: format_date_short(fm["date"]),
        content_snippet: snippet,
        relevance: similarity * 100,
      }
    end

    def extract_sn_links_from_tpns(tpn_items)
      sn_names = []
      tpn_items.each do |item|
        content = @vault.read("#{VaultManager::TPN_DIR}/#{item[:source_name]}.md")
        next unless content

        fm, = Frontmatter.parse(content)
        next unless fm&.dig("summary_notes")

        fm["summary_notes"].first(MAX_SNS_PER_TPN).each do |link|
          sn_names << clean_file_name(link)
        end
      end
      sn_names.uniq
    end

    def fetch_sn_items(sn_names)
      sn_names.uniq.filter_map do |name|
        content = @vault.read("#{VaultManager::SN_DIR}/#{name}.md")
        next unless content

        fm, body = Frontmatter.parse(content)
        next unless fm

        {
          source_type: "SN",
          source_name: name,
          title: fm["title"],
          date: format_date_short(fm["date"]),
          content_snippet: build_sn_snippet(fm, body),
        }
      end
    end

    def build_sn_snippet(fm, body)
      snippet = ""
      if (match = body.match(/## 要約\s*(.*?)(?=\n## |$)/m))
        snippet += "#{match[1].strip[0, 500]}...\n"
      else
        first_para = body.strip.split("\n\n").first
        snippet += "#{first_para.to_s[0, 500]}...\n" if first_para
      end
      if fm["key_takeaways"]&.any?
        snippet += "主なポイント: #{fm['key_takeaways'].join('; ')}\n"
      end
      snippet.strip.empty? ? "関連情報なし" : snippet.strip
    end

    def apply_score_adjustments(items)
      tag_scores = load_tag_scores

      items.each do |item|
        original = item[:relevance] || 0
        adjusted = original

        if item[:source_type] == "TPN"
          tag_name = item[:source_name].sub(/^TPN-/, "")
          score_entry = tag_scores[tag_name]
          if score_entry
            sn_link = (score_entry["last_mentioned_in"] || "").gsub(/\[\[|\]\]/, "")
            if (date_match = sn_link.match(/SN-(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/))
              date_str = "#{date_match[1]}-#{date_match[2]}-#{date_match[3]} #{date_match[4]}:#{date_match[5]}"
              days = days_since(date_str)
              adjusted *= calc_time_decay(days, score_entry["mention_frequency"] || 1) if days
            end
          end
        elsif item[:source_type] == "SN"
          if item[:date]
            days = days_since(item[:date])
            adjusted *= calc_time_decay(days) if days
          end

          # 感情ブースト + importance ブースト
          sn_content = @vault.read("#{VaultManager::SN_DIR}/#{item[:source_name]}.md")
          if sn_content
            fm, = Frontmatter.parse(sn_content)
            if fm
              adjusted *= EMOTION_BOOST_FACTOR if strong_emotion?(fm["mood"])
              adjusted *= importance_factor(fm["importance"])
            end
          end
        end

        item[:relevance] = adjusted
      end
    end

    def format_context_for_llm(items)
      return "記憶からの関連情報は見つかりませんでした。" if items.empty?

      sorted = items.sort_by { |i| -(i[:relevance] || 0) }
      context = ""

      sorted.each do |item|
        time_ago = item[:date] ? format_time_ago(item[:date]) : nil
        time_label = time_ago ? " [#{time_ago}の会話]" : ""

        if item[:source_type] == "TPN"
          tag_label = item[:title]&.sub("タグプロファイル: ", "") || item[:source_name]
          confidence_label = ""
          if item[:confidence]
            confidence_label = " [記憶の確度: 低]" if item[:confidence] < 0.3
            confidence_label = " [記憶の確度: 高]" if item[:confidence] >= 0.7
          end
          context += "\n【#{tag_label} について】#{confidence_label}\n"
        else
          context += "\n[参照元: #{item[:source_type]} - #{item[:source_name]} (#{item[:date] || '日付不明'})#{time_label}]\n"
          context += "タイトル: #{item[:title]}\n" if item[:title]
        end
        context += "#{item[:content_snippet]}\n---\n"
      end

      context
    end

    # --- ユーティリティ ---

    def load_tag_scores
      return @tag_scores_cache if @tag_scores_cache
      content = @vault.read(VaultManager::TAG_SCORES_FILE)
      @tag_scores_cache = content ? JSON.parse(content) : {}
    rescue JSON::ParserError
      @tag_scores_cache = {}
    end

    def calc_time_decay(days_since, mention_frequency = 1)
      effective_rate = BASE_DECAY_RATE / Math.sqrt([mention_frequency, 1].max)
      1.0 / (1.0 + effective_rate * days_since)
    end

    def days_since(date_str)
      parsed = parse_date(date_str)
      return nil unless parsed
      (Time.now - parsed) / 86400.0
    end

    def parse_date(str)
      return nil unless str
      return str if str.is_a?(Time)
      return str.to_time if str.is_a?(Date)

      match = str.to_s.match(/(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?/)
      return nil unless match
      Time.new(match[1].to_i, match[2].to_i, match[3].to_i, match[4].to_i, match[5].to_i, (match[6] || 0).to_i)
    rescue ArgumentError
      nil
    end

    def format_date_short(date_str)
      parsed = parse_date(date_str)
      parsed ? parsed.strftime("%Y-%m-%d %H:%M") : nil
    end

    def format_time_ago(date_str)
      parsed = parse_date(date_str)
      return nil unless parsed

      diff_seconds = Time.now - parsed
      diff_minutes = (diff_seconds / 60).floor

      return "たった今" if diff_minutes < 1
      return "#{diff_minutes}分前" if diff_minutes < 60

      diff_hours = (diff_seconds / 3600).floor
      return "#{diff_hours}時間前" if diff_hours < 24

      diff_days = (diff_seconds / 86400).floor
      return "#{diff_days}日前" if diff_days < 30

      "#{(diff_days / 30).floor}ヶ月前"
    end

    def strong_emotion?(mood)
      return false unless mood
      STRONG_EMOTION_KEYWORDS.any? { |kw| mood.include?(kw) }
    end

    # 1-10 の importance を 0.6x..1.5x の乗算ブーストに変換する
    def importance_factor(importance)
      return 1.0 unless importance.is_a?(Numeric)
      clamped = importance.to_f.clamp(1.0, 10.0)
      1.0 + (clamped - IMPORTANCE_NEUTRAL) * IMPORTANCE_BOOST_PER_POINT
    end

    def deduplicate(items)
      seen = {}
      items.each do |item|
        existing = seen[item[:source_name]]
        if !existing || (item[:relevance] || 0) > (existing[:relevance] || 0)
          seen[item[:source_name]] = item
        end
      end
      seen.values
    end

    def clean_file_name(name)
      name.gsub(/\[\[|\]\]/, "").sub(/\.md$/, "")
    end
  end
end
