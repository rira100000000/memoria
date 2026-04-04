module MemoriaCore
  # 軽量ファサード: vault_pathから初期化し、各Storeへのアクセスと便利メソッドを提供
  # God Objectにはしない。初期化のボイラープレート削減と、複数Storeをまたぐ問い合わせのみ担当
  class Core
    attr_reader :vault, :tpn_store, :sn_store, :fl_store

    def initialize(vault_path)
      @vault = VaultManager.new(vault_path)
      @vault.ensure_structure!
      @tpn_store = TpnStore.new(@vault)
      @sn_store = SnStore.new(@vault)
      @fl_store = FlStore.new(@vault)
    end

    # --- 便利メソッド（必要に応じて段階的に追加） ---

    def tpn_count
      tpn_store.list.length
    end

    def sn_count
      sn_store.list.length
    end

    # 直近のSNの日時を返す
    def last_sn_date
      last_sn = sn_store.list.sort.last
      return nil unless last_sn
      content = vault.read(last_sn)
      return nil unless content
      fm, = Frontmatter.parse(content)
      fm&.dig("date")
    end

    # 直近のユーザー会話からの経過時間（人間が読める形式）
    def last_user_conversation_age
      last_fl = fl_store.list.sort.last
      return "不明" unless last_fl
      timestamp = FlStore.extract_timestamp(File.basename(last_fl))
      return "不明" if timestamp.nil? || timestamp.empty?
      begin
        time = Time.strptime(timestamp, "%Y%m%d%H%M%S") rescue Time.strptime(timestamp, "%Y%m%d%H%M")
        seconds = Time.now - time
        format_duration(seconds)
      rescue
        "不明"
      end
    end

    # 直近のユーザー会話のトピック
    def last_user_conversation_topic
      last_sn = sn_store.list.sort.last
      return "不明" unless last_sn
      content = vault.read(last_sn)
      return "不明" unless content
      fm, = Frontmatter.parse(content)
      fm&.dig("title") || "不明"
    end

    private

    def format_duration(seconds)
      if seconds < 3600
        "#{(seconds / 60).to_i}分前"
      elsif seconds < 86400
        "#{(seconds / 3600).to_i}時間前"
      else
        "#{(seconds / 86400).to_i}日前"
      end
    end
  end
end
