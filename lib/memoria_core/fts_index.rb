require "sqlite3"
require "fileutils"

module MemoriaCore
  # 各 vault ごとの SQLite FTS5 索引。EmbeddingStore (vector) に対する補完として
  # BM25 ベースのキーワード検索を提供する。
  #
  # ファイルは <vault>/.fts.sqlite3 に置かれ、SN/TPN とは別の場所で管理される。
  # ContextRetriever が hybrid_search で vector + BM25 を Reciprocal Rank Fusion
  # で統合するので、ベクトル検索が拾い損ねた固有名詞・キャラクター名・場所名でも
  # 安定して引っ張れるようになる。
  #
  # トークナイザは FTS5 標準の trigram を使う。MeCab/Sudachi のような形態素解析
  # は不要で、3 文字 n-gram で日本語・英語・固有名詞すべてカバーできる。
  class FtsIndex
    INDEX_FILE = ".fts.sqlite3"

    def initialize(vault)
      @vault = vault
      @vault_path = vault.respond_to?(:vault_path) ? vault.vault_path : vault.to_s
      @db_path = File.join(@vault_path, INDEX_FILE)
      @db = nil
    end

    # 索引が無ければ作成する。SN/TPN の登録なしで呼んでも安全
    def initialize!
      ensure_db
      true
    end

    # SN/TPN の内容を索引に upsert する
    # @param file_path [String] vault からの相対パス (= EmbeddingStore のキー)
    # @param source_type [String] "SN" or "TPN"
    # @param content [String] 索引対象のテキスト (frontmatter 込みで構わない)
    def upsert(file_path, source_type, content)
      return false if content.nil? || content.strip.empty?
      d = db
      d.execute("DELETE FROM fts_entries WHERE file_path = ?", [file_path])
      d.execute(
        "INSERT INTO fts_entries(file_path, source_type, content) VALUES (?, ?, ?)",
        [file_path, source_type, content]
      )
      true
    end

    def remove(file_path)
      db.execute("DELETE FROM fts_entries WHERE file_path = ?", [file_path])
    end

    # BM25 検索。score は小さいほど良い (FTS5 の bm25 関数は負の値を返すので符号反転)
    # @return [Array<Hash>] [{ file_path:, source_type:, score: }] (score は降順)
    def search(query, top_k: 10, source_type: nil)
      sanitized = sanitize_query(query)
      return [] if sanitized.empty?

      sql = "SELECT file_path, source_type, bm25(fts_entries) AS bm25_score " \
            "FROM fts_entries WHERE fts_entries MATCH ?"
      bindings = [sanitized]
      if source_type
        sql += " AND source_type = ?"
        bindings << source_type
      end
      sql += " ORDER BY bm25_score LIMIT ?"
      bindings << top_k

      db.execute(sql, bindings).map do |row|
        # FTS5 の bm25 は負の値で「より関連あり」を表す。利便性のため符号反転して
        # 「大きいほど良い」スコアにする
        { file_path: row[0], source_type: row[1], score: -row[2].to_f }
      end
    rescue SQLite3::SQLException => e
      Rails.logger.warn("[FtsIndex] search failed: #{e.message}") if defined?(Rails)
      []
    end

    def count
      db.execute("SELECT COUNT(*) FROM fts_entries").first.first
    end

    # 全件削除
    def clear!
      db.execute("DELETE FROM fts_entries")
    end

    # vault 内の全 SN/TPN ファイルから索引を再構築する。一度きりの初期投入や、
    # 索引が壊れた場合の復旧に使う
    def rebuild_from_vault!
      clear!
      indexed = 0

      [["SN", VaultManager::SN_DIR], ["TPN", VaultManager::TPN_DIR]].each do |source_type, dir|
        @vault.list_markdown_files(dir).each do |file_path|
          content = @vault.read(file_path)
          next unless content
          upsert(file_path, source_type, content)
          indexed += 1
        end
      end

      indexed
    end

    private

    def db
      @db ||= ensure_db
    end

    def ensure_db
      FileUtils.mkdir_p(File.dirname(@db_path))
      conn = SQLite3::Database.new(@db_path)
      conn.execute(<<~SQL)
        CREATE VIRTUAL TABLE IF NOT EXISTS fts_entries USING fts5(
          file_path,
          source_type UNINDEXED,
          content,
          tokenize = 'trigram'
        )
      SQL
      conn
    end

    # FTS5 のクエリ構文には "()*: などの予約文字がある。安全な検索のため、
    # クエリ全体をフレーズ (ダブルクォートで囲む) として扱い、内部のダブル
    # クォートとコントロール文字を除去する
    def sanitize_query(query)
      return "" if query.nil?
      cleaned = query.to_s.gsub(/[\x00-\x1f"]/, " ").strip
      return "" if cleaned.empty?
      "\"#{cleaned}\""
    end
  end
end
