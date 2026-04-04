require_relative "../../lib/memoria_core"

# VAULT_ROOT のデフォルト設定
ENV["VAULT_ROOT"] ||= File.expand_path("~/memoria-vaults")

Rails.logger.info "[Memoria] VAULT_ROOT: #{MemoriaCore.vault_root}"
