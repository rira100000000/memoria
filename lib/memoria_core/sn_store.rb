module MemoriaCore
  # SummaryNote (SN) の読み書き
  class SnStore
    SN_DIR = VaultManager::SN_DIR

    def initialize(vault)
      @vault = vault
    end

    # SNファイルパスを解決（相対パス）
    def path_for(base_name)
      name = base_name.end_with?(".md") ? base_name : "#{base_name}.md"
      File.join(SN_DIR, name)
    end

    # SNを読み込み [frontmatter, body] を返す
    def find(base_name)
      content = @vault.read(path_for(base_name))
      return nil unless content
      Frontmatter.parse(content)
    end

    # SN の生テキストを返す
    def read_raw(base_name)
      @vault.read(path_for(base_name))
    end

    # SNを書き込む
    def save(base_name, frontmatter, body)
      @vault.write(path_for(base_name), Frontmatter.build(frontmatter, body))
    end

    # 全SNファイルパスを返す（ソート済み）
    def list
      @vault.list_markdown_files(SN_DIR)
    end

    # SNをアーカイブ（ファイルは残すがfrontmatterにarchived: trueを付与）
    def archive(base_name)
      content = @vault.read(path_for(base_name))
      return false unless content
      fm, body = Frontmatter.parse(content)
      return false unless fm
      fm["archived"] = true
      fm["archived_at"] = Time.now.strftime("%Y-%m-%d %H:%M")
      @vault.write(path_for(base_name), Frontmatter.build(fm, body))
      true
    end

    # 複数SNを1つに統合。元のSNはアーカイブされる
    # @param base_names [Array<String>] 統合するSNのベース名
    # @param merged_title [String] 統合後のタイトル
    # @param merged_body [String] 統合後の本文
    # @param llm_role_name [String]
    # @return [String] 統合後SNのベース名
    def merge(base_names, merged_title:, merged_body:, llm_role_name:)
      # 元SNの情報を収集
      all_tags = []
      all_takeaways = []
      all_full_logs = []
      source = nil

      base_names.each do |name|
        content = @vault.read(path_for(name))
        next unless content
        fm, = Frontmatter.parse(content)
        next unless fm
        all_tags.concat(Array(fm["tags"]))
        all_takeaways.concat(Array(fm["key_takeaways"]))
        all_full_logs << fm["full_log"] if fm["full_log"]
        source ||= fm["source"]
      end

      # 統合SNを作成
      timestamp = Time.now.strftime("%Y%m%d%H%M")
      merged_base = self.class.build_base_name(timestamp, merged_title)
      merged_fm = {
        "title" => merged_title,
        "date" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "type" => "conversation_summary_merged",
        "tags" => all_tags.uniq,
        "key_takeaways" => all_takeaways.uniq,
        "merged_from" => base_names.map { |n| "[[#{n}.md]]" },
        "full_logs" => all_full_logs.uniq,
        "participants" => ["User", llm_role_name],
      }
      merged_fm["source"] = source if source

      save("#{merged_base}.md", merged_fm, merged_body)

      # 元SNをアーカイブ
      base_names.each { |name| archive(name) }

      merged_base
    end

    # アーカイブされていないSNのみ返す
    def list_active
      list.select { |path|
        content = @vault.read(path)
        next false unless content
        fm, = Frontmatter.parse(content)
        fm&.dig("archived") != true
      }
    end

    # 特定日のSNを返す
    def list_by_date(date)
      date_str = date.strftime("%Y%m%d")
      list.select { |path| File.basename(path).include?(date_str) }
    end

    # タイムスタンプとタイトルからベース名を生成
    def self.build_base_name(timestamp, title)
      sanitized = title.gsub(/[\\\/:"*?<>|#^\[\]]/, "").gsub(/\s+/, "_")[0, 50]
      "SN-#{timestamp}-#{sanitized}"
    end

    # SNのfrontmatterを構築
    # importance: 1-10 の整数。Park et al. (Generative Agents) のスコアリング軸の1つで、
    # 検索時の重み付けに使われる。記録を残す価値の高い会話ほど高スコア。
    def self.build_frontmatter(title:, llm_role_name:, tags:, full_log_ref:, mood:, key_takeaways:, action_items:, semantic_definitions: [], importance: nil)
      fm = {
        "title" => title,
        "date" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "type" => "conversation_summary",
        "participants" => ["User", llm_role_name],
        "tags" => tags,
        "full_log" => "[[#{full_log_ref}]]",
        "mood" => mood || "Neutral",
        "key_takeaways" => key_takeaways || [],
        "action_items" => action_items || [],
      }
      fm["importance"] = importance if importance
      fm["semantic_definitions"] = semantic_definitions if semantic_definitions.any?
      fm
    end
  end
end
