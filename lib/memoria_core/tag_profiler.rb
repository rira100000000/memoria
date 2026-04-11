require "json"

module MemoriaCore
  # SummaryNote のタグからTPNを生成・更新する
  class TagProfiler
    TAG_SCORES_FILE = VaultManager::TAG_SCORES_FILE
    CONCURRENCY = 5 # 将来の並列化用（現在は逐次処理）

    # SN→TPN 昇格ゲート (Park et al. のスコアリング軸を取り入れる)
    # importance_sum >= 10 (例: importance 5 の SN 2 件、または importance 10 の SN 1 件)
    # または mention_frequency >= 3 (importance が低くても繰り返し言及されるテーマは昇格)
    # を満たすまで、新規タグの TPN 生成は遅延される。これにより一過性のタグで
    # TPN が乱立するのを防ぎつつ、単発でも非常に重要な会話は即座に TPN 化される。
    PROMOTION_THRESHOLD_IMPORTANCE_SUM = 10
    PROMOTION_THRESHOLD_FREQUENCY = 3

    def initialize(vault, llm_client, settings = {})
      @vault = vault
      @llm_client = llm_client
      @settings = settings
      @tpn_store = TpnStore.new(vault)
    end

    # SummaryNoteファイルを処理してタグプロファイルを更新
    def process_summary_note(sn_relative_path)
      content = @vault.read(sn_relative_path)
      return unless content

      fm, body = Frontmatter.parse(content)
      return unless fm

      tags = Array(fm["tags"])
      return if tags.empty?

      sn_importance = parse_sn_importance(fm["importance"])

      tag_scores = load_tag_scores
      sn_file_name = File.basename(sn_relative_path)
      sn_base_name = File.basename(sn_relative_path, ".md")
      llm_role_name = @settings[:llm_role_name] || "HAL"
      character_settings = @settings[:system_prompt] || ""

      tags.each do |tag|
        bump_tag_score(tag_scores, tag, sn_file_name, sn_importance)

        unless tag_promoted?(tag, tag_scores[tag])
          if defined?(Rails)
            Rails.logger.info(
              "[TagProfiler] tag '#{tag}' below promotion gate " \
              "(importance_sum=#{tag_scores[tag]["importance_sum"]}, freq=#{tag_scores[tag]["mention_frequency"]}); " \
              "SN counted but TPN deferred"
            )
          end
          next
        end

        unless tag_scores[tag]["promoted_at"]
          tag_scores[tag]["promoted_at"] = Time.now.iso8601
          if defined?(Rails)
            Rails.logger.info(
              "[TagProfiler] promoting tag '#{tag}' to TPN " \
              "(importance_sum=#{tag_scores[tag]["importance_sum"]}, freq=#{tag_scores[tag]["mention_frequency"]})"
            )
          end
        end

        update_tag_profile(
          tag_name: tag,
          sn_file_name: sn_file_name,
          sn_base_name: sn_base_name,
          sn_content: content,
          sn_frontmatter: fm,
          tag_scores: tag_scores,
          llm_role_name: llm_role_name,
          character_settings: character_settings
        )
      rescue => e
        Rails.logger.error("[TagProfiler] Error processing tag '#{tag}': #{e.message}") if defined?(Rails)
      end

      save_tag_scores(tag_scores)
    end

    private

    # SN frontmatter の importance を 1-10 の整数に正規化する
    # 値がない場合は 5 (中立) として扱う。これにより、importance を持たない
    # 旧 SN を処理する際にもゲートロジックが破綻しない
    def parse_sn_importance(raw)
      return 5 if raw.nil?
      n = Integer(raw) rescue nil
      return 5 unless n
      n.clamp(1, 10)
    end

    # tag_scores の集計値を更新する。LLM 呼び出しの有無に関わらず常に呼ばれる
    def bump_tag_score(tag_scores, tag, sn_file_name, sn_importance)
      tag_scores[tag] ||= {
        "base_importance" => 50,
        "mention_frequency" => 0,
        "importance_sum" => 0,
      }
      tag_scores[tag]["mention_frequency"] = (tag_scores[tag]["mention_frequency"] || 0) + 1
      tag_scores[tag]["importance_sum"] = (tag_scores[tag]["importance_sum"] || 0) + sn_importance
      tag_scores[tag]["last_mentioned_in"] = "[[#{sn_file_name}]]"
    end

    # 昇格ゲートの判定。
    # - 既に promoted_at が設定済み: 過去に昇格済みなのでスキップなし
    # - 既存 TPN ファイルが存在: 旧バージョンで作られた TPN は legacy として扱う
    # - importance_sum がしきい値以上: Park et al. の重み付け
    # - mention_frequency がしきい値以上: 反復言及のテーマ
    def tag_promoted?(tag_name, score)
      return true if score["promoted_at"]
      return true if @tpn_store.read_raw(tag_name)
      return true if (score["importance_sum"] || 0) >= PROMOTION_THRESHOLD_IMPORTANCE_SUM
      return true if (score["mention_frequency"] || 0) >= PROMOTION_THRESHOLD_FREQUENCY
      false
    end

    def update_tag_profile(tag_name:, sn_file_name:, sn_base_name:, sn_content:, sn_frontmatter:, tag_scores:, llm_role_name:, character_settings:)
      existing_raw = @tpn_store.read_raw(tag_name)
      existing_fm = nil
      is_new = true

      if existing_raw
        existing_fm, = Frontmatter.parse(existing_raw)
        is_new = existing_fm.nil?
      end

      tpn_fm = existing_fm || TpnStore.initial_frontmatter(tag_name)

      prompt = build_llm_prompt(
        tag_name: tag_name,
        sn_file_name: sn_file_name,
        sn_content: sn_content,
        existing_tpn_content: existing_raw,
        tpn_frontmatter: tpn_fm,
        llm_role_name: llm_role_name,
        character_settings: character_settings
      )

      result = @llm_client.generate(prompt)
      response_text = result.is_a?(Hash) ? result[:text] : result
      parsed = parse_llm_response(response_text, tag_name)
      return unless parsed

      # frontmatter更新
      now = Time.now.strftime("%Y-%m-%d %H:%M")
      tpn_fm["tag_name"] = tag_name
      tpn_fm["aliases"] = parsed["aliases"] || []
      tpn_fm["updated_date"] = now
      tpn_fm["key_themes"] = parsed["key_themes"] || []
      tpn_fm["user_sentiment"] = {
        "overall" => parsed["user_sentiment_overall"] || "不明",
        "details" => parsed["user_sentiment_details"] || [],
      }
      tpn_fm["master_significance"] = parsed["master_significance"] || "記載なし"
      tpn_fm["related_tags"] = (parsed["related_tags"] || []).map { |rt|
        safe = rt.sub(/^TPN-/, "").gsub(/[\\\/:"*?<>|#^\[\]]/, "_")
        "[[TPN-#{safe}]]"
      }

      new_link = "[[#{sn_file_name}]]"
      tpn_fm["summary_notes"] = [new_link] + Array(tpn_fm["summary_notes"]).reject { |l| l == new_link }

      # mention_frequency / last_mentioned_in / importance_sum はゲート判定の前段で
      # bump_tag_score が更新済み。ここでは LLM 由来の base_importance だけ反映する
      if parsed["new_base_importance"].is_a?(Numeric) && parsed["new_base_importance"].between?(0, 100)
        tag_scores[tag_name]["base_importance"] = parsed["new_base_importance"]
      end

      tpn_fm["last_mentioned_in"] = tag_scores[tag_name]["last_mentioned_in"]
      tpn_fm["mention_frequency"] = tag_scores[tag_name]["mention_frequency"]

      has_semantic = parsed["body_semantic"] && parsed["body_semantic"] != "情報なし"
      tpn_fm["memory_type"] = { "semantic" => !!has_semantic, "episodic" => true }

      # confidence算出
      freq = tag_scores[tag_name]["mention_frequency"] || 1
      confidence = [freq / 5.0, 1.0].min
      if tpn_fm["created_date"] && tpn_fm["updated_date"]
        created = Time.parse(tpn_fm["created_date"].tr(" ", "T")) rescue nil
        updated = Time.parse(tpn_fm["updated_date"].tr(" ", "T")) rescue nil
        if created && updated
          span_days = (updated - created) / 86400.0
          confidence = [confidence * 1.1, 1.0].min if span_days > 7
          confidence = [confidence * 1.1, 1.0].min if span_days > 30
        end
      end
      tpn_fm["confidence"] = (confidence * 100).round / 100.0

      # body構築
      body = build_tpn_body(tag_name, parsed, sn_file_name, sn_frontmatter)

      @tpn_store.save(tag_name, tpn_fm, body)
    end

    def build_tpn_body(tag_name, parsed, sn_file_name, sn_frontmatter)
      body = "# タグプロファイル: #{tag_name}\n\n"

      if parsed["body_semantic"] && parsed["body_semantic"] != "���報なし"
        body += "## What it is（意味記憶）\n\n#{parsed['body_semantic']}\n\n"
      end

      body += "## What it means to us（エピソ���ド記憶）\n\n"
      body += "### 概要\n\n#{parsed['body_overview'] || '概要はLLMによって提供されていません。'}\n\n"

      body += "### これまでの主な��脈\n\n"
      contexts = parsed["body_contexts"]
      if contexts.is_a?(Array) && contexts.any?
        contexts.each do |ctx|
          link = ctx["summary_note_link"]
          body += "- **#{link}**: #{ctx['context_summary']}\n"
        end
      else
        body += "- **[[#{sn_file_name}]]**: #{sn_frontmatter&.dig('title') || 'このノートの文脈'}\n"
      end
      body += "\n"

      body += "### ユーザーの意見・反応\n\n"
      opinions = parsed["body_user_opinions"]
      if opinions.is_a?(Array) && opinions.any?
        opinions.each do |op|
          body += "- **#{op['summary_note_link']}**: #{op['user_opinion']}\n"
        end
      else
        body += "- **[[#{sn_file_name}]]**: このノートでのユーザーの意見・反応。\n"
      end
      body += "\n"

      body += "### その他メモ\n\n#{parsed['body_other_notes'] || '特記事項なし。'}\n"
      body
    end

    def build_llm_prompt(tag_name:, sn_file_name:, sn_content:, existing_tpn_content:, tpn_frontmatter:, llm_role_name:, character_settings:)
      today = Time.now.strftime("%Y-%m-%d %H:%M")

      existing_semantic = ""
      existing_contexts = "[]"
      existing_opinions = "[]"

      if existing_tpn_content
        if (m = existing_tpn_content.match(/## What it is（意味記憶）\s*(.*?)(?=\n## What it means to us|$)/m))
          existing_semantic = m[1].strip
        end
        if (m = existing_tpn_content.match(/### これまでの主な文脈\s*(.*?)(?=\n### ユーザーの意見・反応|\n### その他メモ|$)/m))
          entries = parse_list_entries(m[1], :context)
          existing_contexts = JSON.generate(entries) if entries.any?
        end
        if (m = existing_tpn_content.match(/### ユーザーの意見・反���\s*(.*?)(?=\n### その他メモ|$)/m))
          entries = parse_list_entries(m[1], :opinion)
          existing_opinions = JSON.generate(entries) if entries.any?
        end
      end

      <<~PROMPT
        あなたは、以下のキャラクター設定を持つ #{llm_role_name} です。
        このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

        あなたのキャラクター設定:
        ---
        #{character_settings}
        ---

        あなたのタスクは、タグ「#{tag_name}」に関する情報を分析し、既存のタグプロファイリングノート（TPN）を更新するか、新しいTPNを作成することです。
        TPNは「意味記憶（What it is）」と「エ���ソード記憶（What it means to us��」の2層構造で構成されます。
        あなたのキャラクターの視点から、主観的な評価や解釈を含めて記述してください。
        TPNの全てのテキスト内容は Japanese で記述してください。

        **現在の日付:** #{today}

        **入力データ:**

        1. **現在の情報源ノート:**
            * ファイル名: `[[#{sn_file_name}]]`
            * 全文:
                ```markdown
                #{sn_content}
                ```

        2. **既��のTPN「#{tag_name}」の全文:**
            #{existing_tpn_content ? "```markdown\n#{existing_tpn_content}\n```" : "`なし - これは新しいTPNです。`"}

        3. **解析済みの既存TPN本文データ:**
            * 既存の "body_semantic": `#{existing_semantic.empty? ? 'なし' : existing_semantic}`
            * 既存の "body_contexts": ```json\n#{existing_contexts}\n```
            * 既存の "body_user_opinions": ```json\n#{existing_opinions}\n```

        4. **現在のTPNフロントマター:**
            ```yaml
            #{tpn_frontmatter.to_yaml}
            ```

        **出力:** 以下のJSONオブジェクトのみを返してください。
        ```json
        {
          "tag_name": "#{tag_name}",
          "aliases": [],
          "key_themes": [],
          "user_sentiment_overall": "",
          "user_sentiment_details": [],
          "master_significance": "",
          "related_tags": [],
          "body_semantic": "",
          "body_overview": "",
          "body_contexts": [{"summary_note_link": "[[...]]", "context_summary": "..."}],
          "body_user_opinions": [{"summary_note_link": "[[...]]", "user_opinion": "..."}],
          "body_other_notes": "",
          "new_base_importance": 50
        }
        ```
      PROMPT
    end

    def parse_llm_response(response, tag_name)
      json_match = response.match(/```json\s*(.*?)\s*```/m)
      json_str = json_match ? json_match[1] : response
      parsed = JSON.parse(json_str)
      parsed["tag_name"] = tag_name
      parsed
    rescue JSON::ParserError => e
      Rails.logger.error("[TagProfiler] JSON parse error for '#{tag_name}': #{e.message}") if defined?(Rails)
      nil
    end

    def parse_list_entries(text, type)
      entries = []
      text.strip.split("\n").each do |line|
        match = line.match(/- \*?\*?(\S*\[\[.*?\]\]\S*)\*?\*?:\s*(.*)/)
        next unless match
        if type == :context
          entries << { "summary_note_link" => match[1], "context_summary" => match[2].strip }
        else
          entries << { "summary_note_link" => match[1], "user_opinion" => match[2].strip }
        end
      end
      entries
    end

    def load_tag_scores
      content = @vault.read(TAG_SCORES_FILE)
      content ? JSON.parse(content) : {}
    rescue JSON::ParserError
      {}
    end

    def save_tag_scores(scores)
      @vault.write(TAG_SCORES_FILE, JSON.pretty_generate(scores))
    end
  end
end
