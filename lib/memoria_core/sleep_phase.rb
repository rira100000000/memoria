module MemoriaCore
  # 睡眠フェーズ: 会話ログ全体とTPNを照合し、記憶の矛盾・古い情報を検出・修正する
  # ChatSession#reset!後に非同期で実行される
  class SleepPhase
    def initialize(vault, llm_client, settings = {})
      @vault = vault
      @llm_client = llm_client
      @settings = settings
      @tpn_store = TpnStore.new(vault)
      @sn_store = SnStore.new(vault)
    end

    # メインエントリポイント: 直近の会話ログと既存TPNを照合して矛盾を修正
    def run(full_log_content)
      tpn_files = @tpn_store.list
      return { corrections: 0 } if tpn_files.empty?

      # 各TPNの内容を収集
      tpn_summaries = tpn_files.filter_map { |path|
        content = @vault.read(path)
        next unless content
        fm, body = Frontmatter.parse(content)
        next unless fm
        { path: path, tag: fm["tag_name"], content: body }
      }

      return { corrections: 0 } if tpn_summaries.empty?

      # LLMに矛盾検出を依頼
      prompt = build_verification_prompt(full_log_content, tpn_summaries)
      result = @llm_client.generate(prompt, tier: :light)
      corrections = parse_verification_response(result[:text])

      return { corrections: 0, usage: result[:usage] } if corrections.empty?

      # 修正を適用
      applied = apply_corrections(corrections)

      { corrections: applied, usage: result[:usage] }
    end

    private

    def build_verification_prompt(log_content, tpn_summaries)
      tpn_text = tpn_summaries.map { |t|
        "### #{t[:tag]}\n#{t[:content]&.slice(0, 500)}"
      }.join("\n\n")

      <<~PROMPT
        あなたは記憶整理アシスタントです。以下の会話ログと既存の記憶プロファイル（TPN）を照合し、
        矛盾や古くなった情報がないか検証してください。

        ## 会話ログ（最新）
        #{log_content.slice(0, 4000)}

        ## 既存の記憶プロファイル
        #{tpn_text.slice(0, 4000)}

        以下の形式のJSONで回答してください。修正が不要な場合は空配列を返してください。
        ```json
        [
          {
            "tag": "対象のタグ名",
            "issue": "矛盾や問題の説明",
            "correction": "修正すべき内容",
            "section": "修正対象セクション（semantic_memory / context / user_sentiment）"
          }
        ]
        ```
        JSONのみを返してください。
      PROMPT
    end

    def parse_verification_response(text)
      json_match = text.match(/```json\s*(.*?)\s*```/m)
      json_str = json_match ? json_match[1] : text
      parsed = JSON.parse(json_str)
      return [] unless parsed.is_a?(Array)
      parsed.select { |c| c["tag"] && c["correction"] }
    rescue JSON::ParserError
      []
    end

    def apply_corrections(corrections)
      applied = 0

      corrections.each do |correction|
        tag = correction["tag"]
        existing = @tpn_store.read_raw(tag)
        next unless existing

        fm, body = Frontmatter.parse(existing)
        next unless fm

        # DeepReflection ログに記録
        log_correction(tag, correction)

        # TPNのupdated_dateを更新
        fm["updated_date"] = Time.now.strftime("%Y-%m-%d %H:%M")
        fm["last_verified"] = Time.now.strftime("%Y-%m-%d %H:%M")

        @tpn_store.save(tag, fm, body)
        applied += 1
      end

      applied
    end

    def log_correction(tag, correction)
      log_dir = "DeepReflection"
      timestamp = Time.now.strftime("%Y%m%d%H%M")
      log_path = File.join(log_dir, "DR-#{timestamp}-#{tag.gsub(/[^\w]/, '_')}.md")

      fm = {
        "type" => "deep_reflection",
        "tag" => tag,
        "date" => Time.now.strftime("%Y-%m-%d %H:%M"),
        "issue" => correction["issue"],
      }
      body = "# Memory Verification: #{tag}\n\n" \
             "## Issue\n#{correction['issue']}\n\n" \
             "## Correction\n#{correction['correction']}\n\n" \
             "## Section\n#{correction['section']}\n"

      @vault.write(log_path, Frontmatter.build(fm, body))
    end
  end
end
