require "shellwords"

module MemoriaCore
  # Vaultをローカルgitリポジトリとして管理し、記憶変更時にスナップショットを取る
  # リモートリポジトリは使わない（ローカル限定）
  class VaultVersioning
    def initialize(vault)
      @vault = vault
      @repo_path = vault.vault_path
    end

    def ensure_repo!
      return if File.exist?(File.join(@repo_path, ".git"))
      git("init", "--quiet")
      git("config", "user.name", "memoria")
      git("config", "user.email", "memoria@local")
      File.write(File.join(@repo_path, ".gitignore"), <<~GITIGNORE)
        embedding_index.json
        FullLog/
      GITIGNORE
      git("add", "-A")
      git("commit", "--quiet", "-m", "Initial vault state")
    end

    # スナップショットコミット
    # 変更がなければコミットしない
    def commit_snapshot(trigger, message = nil)
      git("add", "-A")
      return false if no_changes?
      msg = message || "#{trigger}: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
      result = git("commit", "--quiet", "-m", msg)
      Rails.logger.info("[VaultVersioning] #{msg}") if result && defined?(Rails)
      result
    end

    # 特定のコミットまでロールバック
    def rollback_to(commit_sha)
      result = git("checkout", commit_sha, "--", ".")
      unless result
        Rails.logger.error("[VaultVersioning] rollback_to #{commit_sha} failed") if defined?(Rails)
        return false
      end
      git("add", "-A")
      git("commit", "--quiet", "-m", "Rollback to #{commit_sha}")
    end

    # 直近のコミット履歴
    def recent_history(limit = 20)
      output = `git -C #{Shellwords.escape(@repo_path)} log --oneline -#{limit} 2>/dev/null`.strip
      output.split("\n").map do |line|
        sha, *msg = line.split(" ")
        { sha: sha, message: msg.join(" ") }
      end
    end

    private

    def no_changes?
      system("git", "-C", @repo_path, "diff", "--cached", "--quiet",
             out: File::NULL, err: File::NULL)
    end

    # git -C を使ってDir.chdirを避ける（Sidekiq並行性対策）
    def git(*args)
      success = system("git", "-C", @repo_path, *args,
                       out: File::NULL, err: File::NULL)
      unless success
        Rails.logger.warn("[VaultVersioning] git #{args.first} failed (exit: #{$?.exitstatus})") if defined?(Rails)
      end
      success
    end
  end
end
