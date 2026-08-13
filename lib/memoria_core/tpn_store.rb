module MemoriaCore
  # TagProfilingNote (TPN) の読み書き
  class TpnStore
    TPN_DIR = VaultManager::TPN_DIR

    def initialize(vault)
      @vault = vault
    end

    # タグ名からTPNファイルパスを解決
    def path_for(tag_name)
      safe = sanitize_tag(tag_name)
      File.join(TPN_DIR, "TPN-#{safe}.md")
    end

    # TPNを読み込み [frontmatter, body] を返す。存在しなければ nil
    def find(tag_name)
      content = @vault.read(path_for(tag_name))
      return nil unless content
      Frontmatter.parse(content)
    end

    # TPN の生テキストを返す
    def read_raw(tag_name)
      @vault.read(path_for(tag_name))
    end

    # TPNを書き込む
    def save(tag_name, frontmatter, body)
      @vault.write(path_for(tag_name), Frontmatter.build(frontmatter, body))
    end

    # 全TPNファイルパスを返す
    def list
      @vault.list_markdown_files(TPN_DIR)
    end

    # 新規TPN用の初期frontmatterを生成
    def self.initial_frontmatter(tag_name)
      now = Time.now.strftime("%Y-%m-%d %H:%M")
      {
        "tag_name" => tag_name,
        "type" => "tag_profile",
        "created_date" => now,
        "updated_date" => now,
        "aliases" => [],
        "key_themes" => [],
        "user_sentiment" => { "overall" => "Neutral", "details" => [] },
        "master_significance" => "",
        "related_tags" => [],
        "summary_notes" => [],
      }
    end

    private

    def sanitize_tag(tag_name)
      tag_name.gsub(/[\\\/:"*?<>|#^\[\]]/, "_")
    end
  end
end
