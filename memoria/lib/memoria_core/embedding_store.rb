require "json"

module MemoriaCore
  # Embedding のインメモリ管理・永続化・類似検索
  class EmbeddingStore
    EMBEDDING_MODEL = "gemini-embedding-001"

    attr_reader :entry_count

    # @param vault [VaultManager]
    # @param llm_client [#embed(text) -> Array<Float>] Embedding API呼び出し用
    def initialize(vault, llm_client = nil)
      @vault = vault
      @llm_client = llm_client
      @index = { "version" => 1, "model" => EMBEDDING_MODEL, "entries" => {} }
    end

    def initialize!
      load_index
    end

    def entry_count
      @index["entries"].size
    end

    # テキストのembeddingを生成し、インデックスに保存
    def embed_and_store(file_path, content, source_type, metadata = {})
      return false unless @llm_client&.embedding_available?

      content_hash = compute_hash(content)
      existing = @index["entries"][file_path]
      return true if existing && existing["contentHash"] == content_hash

      embedding = @llm_client.embed(content)
      @index["entries"][file_path] = {
        "filePath" => file_path,
        "sourceType" => source_type,
        "contentHash" => content_hash,
        "embedding" => embedding,
        "title" => metadata[:title],
        "tags" => metadata[:tags],
        "updatedAt" => Time.now.iso8601,
      }
      save_index
      true
    rescue => e
      Rails.logger.error("[EmbeddingStore] Error embedding #{file_path}: #{e.message}") if defined?(Rails)
      false
    end

    # クエリテキストのembeddingを生成
    def embed_query(text)
      return nil unless @llm_client&.embedding_available?
      @llm_client.embed(text)
    rescue => e
      Rails.logger.error("[EmbeddingStore] Error embedding query: #{e.message}") if defined?(Rails)
      nil
    end

    # 類似エントリを検索
    # @return [Array<Hash>] { entry:, similarity: }
    def find_similar(query_embedding, top_k: 5, min_similarity: 0.3, source_type_filter: nil)
      results = []

      @index["entries"].each_value do |entry|
        next if source_type_filter && source_type_filter != "all" && entry["sourceType"] != source_type_filter

        sim = cosine_similarity(query_embedding, entry["embedding"])
        results << { entry: entry, similarity: sim } if sim >= min_similarity
      end

      results.sort_by { |r| -r[:similarity] }.first(top_k)
    end

    def remove_entry(file_path)
      @index["entries"].delete(file_path)
    end

    # インデックスを全て再構築
    def rebuild_index!
      return 0 unless @llm_client&.embedding_available?

      @index["entries"] = {}
      files_to_embed = []

      @vault.list_markdown_files(VaultManager::TPN_DIR).each { |f| files_to_embed << [f, "TPN"] }
      @vault.list_markdown_files(VaultManager::SN_DIR).each { |f| files_to_embed << [f, "SN"] }

      embedded = 0
      files_to_embed.each do |file_path, source_type|
        content = @vault.read(file_path)
        next unless content && !content.strip.empty?

        fm, body = Frontmatter.parse(content)
        next if body.strip.empty?

        text = prepare_text_for_embedding(body, fm, source_type)
        embedding = @llm_client.embed(text)
        content_hash = compute_hash(text)

        base_name = File.basename(file_path, ".md")
        @index["entries"][file_path] = {
          "filePath" => file_path,
          "sourceType" => source_type,
          "contentHash" => content_hash,
          "embedding" => embedding,
          "title" => fm&.dig("title") || fm&.dig("tag_name") || base_name,
          "tags" => fm&.dig("tags") || (fm&.dig("tag_name") ? [fm["tag_name"]] : []),
          "updatedAt" => Time.now.iso8601,
        }
        embedded += 1
      rescue => e
        Rails.logger.error("[EmbeddingStore] Error embedding #{file_path}: #{e.message}") if defined?(Rails)
      end

      save_index
      embedded
    end

    private

    def load_index
      content = @vault.read(VaultManager::EMBEDDING_INDEX_FILE)
      return unless content

      parsed = JSON.parse(content)
      if parsed["model"] == EMBEDDING_MODEL
        @index = parsed
      end
    rescue JSON::ParserError => e
      Rails.logger.error("[EmbeddingStore] Error loading index: #{e.message}") if defined?(Rails)
    end

    def save_index
      @vault.write(VaultManager::EMBEDDING_INDEX_FILE, JSON.pretty_generate(@index))
    end

    def compute_hash(content)
      # シンプルなハッシュ（TS版と互換）
      hash = 0
      content.each_char do |c|
        hash = ((hash << 5) - hash) + c.ord
        hash &= 0xFFFFFFFF # 32bit整数に制限
        hash = hash > 0x7FFFFFFF ? hash - 0x100000000 : hash
      end
      hash.to_s(36)
    end

    def cosine_similarity(a, b)
      return 0.0 if a.length != b.length

      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      a.length.times do |i|
        dot += a[i] * b[i]
        norm_a += a[i] * a[i]
        norm_b += b[i] * b[i]
      end
      denom = Math.sqrt(norm_a) * Math.sqrt(norm_b)
      denom.zero? ? 0.0 : dot / denom
    end

    def prepare_text_for_embedding(body, frontmatter, source_type)
      text = ""
      if frontmatter
        text += "タイトル: #{frontmatter['title']}\n" if frontmatter["title"]
        text += "タグ: #{frontmatter['tag_name']}\n" if frontmatter["tag_name"]
        text += "テーマ: #{Array(frontmatter['key_themes']).join(', ')}\n" if frontmatter["key_themes"]
        text += "ポイント: #{Array(frontmatter['key_takeaways']).join(', ')}\n" if frontmatter["key_takeaways"]
        text += "タグ: #{Array(frontmatter['tags']).join(', ')}\n" if frontmatter["tags"]
      end
      text + body[0, 4000]
    end
  end
end
