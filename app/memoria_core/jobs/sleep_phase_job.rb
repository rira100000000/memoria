# チャットリセット時に会話ログ全体と既存TPNを照合して記憶の矛盾を検出・修正するジョブ
class SleepPhaseJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  def perform(character_id, full_log_path)
    character = Character.find(character_id)

    # バジェットチェック（自発的行動扱い）
    unless ApiBudget.can_spend?(character.user, "sleep_phase")
      Rails.logger.info("[SleepPhaseJob] Budget exceeded for User##{character.user_id}, skipping")
      return
    end

    vault = MemoriaCore::VaultManager.new(character.vault_path)
    full_log_content = vault.read(full_log_path)
    return unless full_log_content

    tracker = ->(model, usage) {
      ApiUsageLog.record!(
        user: character.user,
        character: character,
        trigger_type: "sleep_phase",
        llm_model: model,
        usage: usage
      )
    }
    llm_client = LlmClient.new(usage_tracker: tracker)

    vault.versioning.commit_snapshot("pre_sleep_phase")

    sleep_phase = MemoriaCore::SleepPhase.new(vault, llm_client, {
      llm_role_name: character.name,
    })
    result = sleep_phase.run(full_log_content)

    vault.versioning.commit_snapshot("post_sleep_phase", "sleep_phase: #{result[:corrections]}件の矛盾を修正")

    Rails.logger.info("[SleepPhaseJob] Completed for Character##{character_id}: #{result[:corrections]} corrections")
  rescue => e
    Rails.logger.error("[SleepPhaseJob] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    raise
  end
end
