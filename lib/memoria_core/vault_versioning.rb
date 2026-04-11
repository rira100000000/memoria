require "open3"

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
      output = capture_git("log", "--oneline", "-#{limit.to_i}")
      output.split("\n").map do |line|
        sha, *msg = line.split(" ")
        { sha: sha, message: msg.join(" ") }
      end
    end

    # --- ブランチ操作 ---

    def current_branch
      output = capture_git("branch", "--show-current")
      output.empty? ? nil : output
    end

    def list_branches
      output = capture_git("branch", "--format=%(refname:short)")
      output.split("\n")
    end

    def create_branch(name)
      git("checkout", "-b", name)
    end

    def checkout_branch(name)
      git("checkout", name)
    end

    def delete_branch(name)
      git("branch", "-D", name)
    end

    def merge_branch(name, into:)
      current = current_branch
      return false unless checkout_branch(into)
      result = git("merge", "--no-ff", "-m", "Merge #{name} into #{into}", name)
      checkout_branch(current) if current && current != into && result == false
      result
    end

    # 現在のHEADコミットshaを返す
    def head_sha
      output = capture_git("rev-parse", "HEAD")
      output.empty? ? nil : output
    end

    private

    def no_changes?
      system("git", "-C", @repo_path, "diff", "--cached", "--quiet",
             out: File::NULL, err: File::NULL)
    end

    # git -C を使ってDir.chdirを避ける（並行ジョブ実行時のスレッドセーフ対策）
    # 引数は配列で system に渡すため shell を経由せず、コマンドインジェクションは構造的に発生しない
    def git(*args)
      success = system("git", "-C", @repo_path, *args,
                       out: File::NULL, err: File::NULL)
      unless success
        Rails.logger.warn("[VaultVersioning] git #{args.first} failed (exit: #{$?.exitstatus})") if defined?(Rails)
      end
      success
    end

    # stdout を取得する系の git 呼び出し。Open3 を使うことで shell を経由せず、
    # 引数の interpolation があっても構造的に injection が発生しない
    def capture_git(*args)
      stdout, _status = Open3.capture2("git", "-C", @repo_path, *args)
      stdout.strip
    rescue => e
      Rails.logger.warn("[VaultVersioning] capture_git failed: #{e.message}") if defined?(Rails)
      ""
    end
  end
end
