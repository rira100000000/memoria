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

    # タイムスタンプとタイトルからベース名を生成
    def self.build_base_name(timestamp, title)
      sanitized = title.gsub(/[\\\/:"*?<>|#^\[\]]/, "").gsub(/\s+/, "_")[0, 50]
      "SN-#{timestamp}-#{sanitized}"
    end

    # SNのfrontmatterを構築
    def self.build_frontmatter(title:, llm_role_name:, tags:, full_log_ref:, mood:, key_takeaways:, action_items:, semantic_definitions: [])
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
      fm["semantic_definitions"] = semantic_definitions if semantic_definitions.any?
      fm
    end
  end
end
