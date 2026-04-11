module MemoriaCore
  class << self
    def vault_root
      File.expand_path(ENV.fetch("VAULT_ROOT", "~/memoria-vaults"))
    end
  end
end

require_relative "memoria_core/vault_versioning"
require_relative "memoria_core/vault_manager"
require_relative "memoria_core/frontmatter"
require_relative "memoria_core/tpn_store"
require_relative "memoria_core/sn_store"
require_relative "memoria_core/fl_store"
require_relative "memoria_core/embedding_store"
require_relative "memoria_core/fts_index"
require_relative "memoria_core/context_retriever"
require_relative "memoria_core/tag_profiler"
require_relative "memoria_core/chat_logger"
