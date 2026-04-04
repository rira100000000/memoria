module MemoriaCore
  # FullLog (FL) の読み書き
  class FlStore
    FL_DIR = VaultManager::FL_DIR

    def initialize(vault)
      @vault = vault
    end

    # 新しいログファイルを作成し、相対パスを返す
    def create(llm_role_name)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      file_name = "#{timestamp}.md"
      relative_path = File.join(FL_DIR, file_name)

      now_str = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      content = <<~MD
        ---
        title: undefined
        date: #{now_str}
        type: full_log
        summary_note: undefined
        participants:
          - User
          - #{llm_role_name}
        ---
        # 会話ログ: undefined
        **日時**: #{now_str}
        ---
      MD

      @vault.write(relative_path, content)
      relative_path
    end

    # ログファイルにエントリを追記
    def append(relative_path, entry)
      full = @vault.path_for(relative_path)
      File.open(full, "a", encoding: "utf-8") { |f| f.write(entry) }
    end

    # frontmatterを更新
    def update_frontmatter(relative_path, updates)
      content = @vault.read(relative_path)
      return unless content

      fm, body = Frontmatter.parse(content)
      return unless fm

      updates.each { |k, v| fm[k.to_s] = v }
      @vault.write(relative_path, Frontmatter.build(fm, body))
    end

    # ログファイルを削除
    def delete(relative_path)
      @vault.delete(relative_path)
    end

    # ログファイル名からタイムスタンプ部分（12桁）を抽出
    def self.extract_timestamp(file_name)
      base = File.basename(file_name, ".md")
      match = base.match(/(\d{12,14})/)
      match ? match[1][0, 12] : Time.now.strftime("%Y%m%d%H%M")
    end
  end
end
