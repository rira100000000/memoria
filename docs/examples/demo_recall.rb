# デモ用vaultに対して記憶検索（recall）を試すスクリプト。
# ベクトル検索が使えない場合はBM25（SQLite FTS5）のみで検索される。
#
#   GEMINI_API_KEY=dummy bin/rails runner docs/examples/demo_recall.rb
#
require "tmpdir"
require "fileutils"

Dir.mktmpdir do |tmp|
  vault_path = File.join(tmp, "demo")
  FileUtils.mkdir_p(vault_path)
  FileUtils.cp_r(Rails.root.join("docs/examples/demo_vault/SummaryNote"), vault_path)

  vault = MemoriaCore::VaultManager.new(vault_path)
  vault.ensure_structure!

  index = MemoriaCore::FtsIndex.new(vault)
  index.initialize!
  puts "FTS indexed: #{index.rebuild_from_vault!} entries"

  store = MemoriaCore::EmbeddingStore.new(vault, LlmClient.new)
  store.initialize!

  retriever = MemoriaCore::ContextRetriever.new(vault, store, fts_index: index)
  %w[花火大会 コーヒー 羅生門].each do |query|
    result = retriever.retrieve(query)
    puts "\n## query: #{query} (#{result[:retrieved_items].length} hits)"
    puts result[:llm_context_prompt].lines.first(4).join
  end
end
