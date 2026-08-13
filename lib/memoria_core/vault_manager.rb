require "fileutils"

module MemoriaCore
  class VaultManager
    TPN_DIR = "TagProfilingNote"
    SN_DIR  = "SummaryNote"
    FL_DIR  = "FullLog"
    TAG_SCORES_FILE = "tag_scores.json"
    EMBEDDING_INDEX_FILE = "embedding_index.json"

    SUBDIRS = [TPN_DIR, SN_DIR, FL_DIR].freeze

    attr_reader :vault_path

    def initialize(vault_path)
      @vault_path = vault_path
    end

    def ensure_structure!
      FileUtils.mkdir_p(vault_path)
      SUBDIRS.each { |dir| FileUtils.mkdir_p(File.join(vault_path, dir)) }
      versioning.ensure_repo!
    end

    def versioning
      @versioning ||= VaultVersioning.new(self)
    end

    def path_for(*segments)
      File.join(vault_path, *segments)
    end

    def read(relative_path)
      full = path_for(relative_path)
      File.exist?(full) ? File.read(full, encoding: "utf-8") : nil
    end

    def write(relative_path, content)
      full = path_for(relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content, encoding: "utf-8")
    end

    def exist?(relative_path)
      File.exist?(path_for(relative_path))
    end

    def delete(relative_path)
      full = path_for(relative_path)
      File.delete(full) if File.exist?(full)
    end

    def list_markdown_files(dir)
      full_dir = path_for(dir)
      return [] unless Dir.exist?(full_dir)

      Dir.glob(File.join(full_dir, "*.md")).map { |f| File.join(dir, File.basename(f)) }.sort
    end

    def tag_scores_path
      path_for(TAG_SCORES_FILE)
    end

    def embedding_index_path
      path_for(EMBEDDING_INDEX_FILE)
    end
  end
end
