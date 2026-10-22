# 会話の外の体験（思考ループ、プラグインが渡した読書の記録など）を記憶に残す。
# 全文を FullLog に保存し、振り返って SummaryNote を作り、タグの理解を更新する
class MemorizeService
  # @param source [String] 体験の種類。FL と SN の frontmatter の source に入る。"reading" は読書の振り返り方で振り返る
  # @param metadata [Hash] FL の frontmatter に足す値（participants、作品名など）
  # @return [Hash, nil] { full_log_path:, summary_note_path: }。text が空なら nil
  def self.run(character, text:, source:, metadata: {}, llm_client: nil)
    return nil if text.to_s.strip.empty?

    core = MemoriaCore::Core.new(character.vault_path)
    llm_client ||= LlmClient.new(usage_tracker: usage_tracker(character))

    fl_store = core.fl_store
    fl_path = fl_store.create(character.name)
    fl_store.append(fl_path, text)
    fl_store.update_frontmatter(fl_path, metadata.to_h.transform_keys(&:to_s).merge("source" => source))

    reflection = ReflectionService.new(character, llm_client: llm_client).generate(
      conversation_text: text,
      full_log_ref: File.basename(fl_path),
      timestamp: Time.now.strftime("%Y%m%d%H%M"),
      context_type: source == "reading" ? :reading : nil,
    )
    return { full_log_path: fl_path, summary_note_path: nil } unless reflection

    mark_source(core, reflection[:file_path], source)
    TagProfilingJob.perform_later(character.id, reflection[:file_path])
    { full_log_path: fl_path, summary_note_path: reflection[:file_path] }
  end

  def self.mark_source(core, sn_path, source)
    content = core.vault.read(sn_path)
    return unless content

    fm, body = MemoriaCore::Frontmatter.parse(content)
    return unless fm

    fm["source"] = source
    core.vault.write(sn_path, MemoriaCore::Frontmatter.build(fm, body))
  end

  def self.usage_tracker(character)
    lambda { |model, usage|
      begin
        ApiUsageLog.record!(user: character.user, character: character, trigger_type: "memorize", llm_model: model, usage: usage)
      rescue => e
        Rails.logger.warn("[MemorizeService] Usage tracking failed: #{e.message}")
      end
    }
  end
end
