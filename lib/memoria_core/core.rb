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

    # --- カウント ---

    def tpn_count
      tpn_store.list.length
    end

    def sn_count
      sn_store.list.length
    end

    # --- 直近の会話情報 ---

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
      last_fl = user_conversation_fls.last
      return "不明" unless last_fl
      time = parse_fl_timestamp(last_fl)
      return "不明" unless time
      format_duration(Time.now - time)
    end

    # 直近のユーザー会話のトピック
    def last_user_conversation_topic
      last_sn = user_conversation_sns.last
      return "不明" unless last_sn
      content = vault.read(last_sn)
      return "不明" unless content
      fm, = Frontmatter.parse(content)
      fm&.dig("title") || "不明"
    end

    # --- 自律活動ログ ---

    # 直近の自律活動のサマリー
    def last_autonomous_log_summary
      last_sn = autonomous_sns.last
      return nil unless last_sn
      content = vault.read(last_sn)
      return nil unless content
      fm, = Frontmatter.parse(content)
      fm&.dig("title")
    end

    # 直近N日間の自律活動SN（ThoughtHealthMonitor用）
    def recent_autonomous_sns(days: 7)
      cutoff = Time.now - days * 86400
      autonomous_sns.filter_map { |path|
        content = vault.read(path)
        next unless content
        fm, body = Frontmatter.parse(content)
        next unless fm
        date = parse_date_value(fm["date"])
        next if date && date < cutoff
        { path: path, frontmatter: fm, body: body }
      }
    end

    # 直近N日間の全SN（ユーザー会話 + 自律活動）
    def recent_sns(days: 7)
      cutoff = Time.now - days * 86400
      sn_store.list.sort.filter_map { |path|
        content = vault.read(path)
        next unless content
        fm, body = Frontmatter.parse(content)
        next unless fm
        date = parse_date_value(fm["date"])
        next if date && date < cutoff
        { path: path, frontmatter: fm, body: body }
      }
    end

    # 前回の自律活動で「続き」があるか
    def pending_continuation
      last_sn = autonomous_sns.last
      return nil unless last_sn
      content = vault.read(last_sn)
      return nil unless content
      fm, = Frontmatter.parse(content)
      return nil unless fm
      items = Array(fm["action_items"]).select { |i| i.to_s.strip.present? }
      return nil if items.empty?
      { topic: fm["title"], items: items }
    end

    private

    # ユーザー会話のFL（source: autonomousでないもの）
    def user_conversation_fls
      fl_store.list.sort.select { |path|
        content = vault.read(path)
        next false unless content
        fm, = Frontmatter.parse(content)
        fm&.dig("source") != "autonomous"
      }
    end

    # ユーザー会話のSN
    def user_conversation_sns
      sn_store.list.sort.select { |path|
        content = vault.read(path)
        next false unless content
        fm, = Frontmatter.parse(content)
        fm&.dig("source") != "autonomous"
      }
    end

    # 自律活動のSN
    def autonomous_sns
      sn_store.list.sort.select { |path|
        content = vault.read(path)
        next false unless content
        fm, = Frontmatter.parse(content)
        fm&.dig("source") == "autonomous"
      }
    end

    def parse_fl_timestamp(path)
      timestamp = FlStore.extract_timestamp(File.basename(path))
      return nil if timestamp.nil? || timestamp.empty?
      Time.strptime(timestamp, "%Y%m%d%H%M%S") rescue Time.strptime(timestamp, "%Y%m%d%H%M") rescue nil
    end

    def parse_date_value(val)
      return val if val.is_a?(Time)
      return val.to_time if val.is_a?(Date)
      return nil unless val.is_a?(String)
      match = val.match(/(\d{4})-(\d{2})-(\d{2})/)
      return nil unless match
      Time.new(match[1].to_i, match[2].to_i, match[3].to_i) rescue nil
    end

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
