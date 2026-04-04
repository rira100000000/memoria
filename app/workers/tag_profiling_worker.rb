# チャットリセット時のタグプロファイリングを非同期実行するワーカー
# ChatSession#reset!で生成されたSNのタグを元にTPNを更新する
class TagProfilingWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 2

  def perform(character_id, sn_file_path)
    character = Character.find(character_id)
    vault = MemoriaCore::VaultManager.new(character.vault_path)
    llm_client = LlmClient.new
    embedding_store = MemoriaCore::EmbeddingStore.new(vault, llm_client)
    embedding_store.initialize!

    tag_profiler = MemoriaCore::TagProfiler.new(vault, llm_client, {
      llm_role_name: character.name,
      system_prompt: character.system_prompt,
    })
    tag_profiler.process_summary_note(sn_file_path)

    # 更新されたTPNのEmbeddingを再生成
    content = vault.read(sn_file_path)
    return unless content
    fm, = MemoriaCore::Frontmatter.parse(content)
    return unless fm

    tpn_store = MemoriaCore::TpnStore.new(vault)
    Array(fm["tags"]).each do |tag|
      tpn_content = tpn_store.read_raw(tag)
      next unless tpn_content
      embedding_store.embed_and_store(
        tpn_store.path_for(tag), tpn_content, "TPN",
        { title: tag, tags: [tag] }
      )
    end

    Rails.logger.info("[TagProfilingWorker] Completed for Character##{character_id}, SN: #{sn_file_path}")
  rescue => e
    Rails.logger.error("[TagProfilingWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    raise # Sidekiqのリトライに任せる
  end
end
