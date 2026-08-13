module MemoriaCore
  # 会話ログの md ファイル出力を管理
  class ChatLogger
    def initialize(vault, llm_role_name)
      @vault = vault
      @llm_role_name = llm_role_name
      @fl_store = FlStore.new(vault)
      @current_log_path = nil
    end

    attr_reader :current_log_path

    # 新しいログファイルを作成
    def setup!
      @current_log_path = @fl_store.create(@llm_role_name)
    end

    # 既存のログパスを復元（セッション再開時に使用）
    def restore!(log_path)
      @current_log_path = log_path
    end

    # ユーザーメッセージを記録
    def log_user_message(content)
      return unless @current_log_path
      @fl_store.append(@current_log_path, "\n**User**: #{content}\n")
    end

    # AI応答を記録
    def log_ai_message(content)
      return unless @current_log_path
      @fl_store.append(@current_log_path, "\n**#{@llm_role_name}**: #{content}\n")
    end

    # frontmatterを更新（title, summary_note等）
    def update_frontmatter(updates)
      return unless @current_log_path
      @fl_store.update_frontmatter(@current_log_path, updates)
    end

    # ログファイルを削除
    def delete_current!
      return unless @current_log_path
      @fl_store.delete(@current_log_path)
      @current_log_path = nil
    end

    # リセット
    def reset!
      @current_log_path = nil
    end

    # ログファイル名（拡張子付き）
    def log_file_name
      @current_log_path ? File.basename(@current_log_path) : nil
    end
  end
end
