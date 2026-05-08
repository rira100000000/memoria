namespace :ms do
  namespace :admin do
    desc "MS の最初の管理キーを発行する。LABEL=... で識別ラベルを付与可能。"
    task bootstrap: :environment do
      label = ENV.fetch("LABEL", "bootstrap")

      if AdminKey.active.exists?
        puts "[ms:admin:bootstrap] 既に有効な管理キーが #{AdminKey.active.count} 件存在します。"
        puts "  追加発行する場合は 'ms:admin:issue LABEL=...' を使ってください。"
        next
      end

      plain = AdminKey.issue!(label: label)
      print_key("ADMIN KEY", plain, label: label)
    end

    desc "追加の管理キーを発行する。LABEL=... 必須。"
    task issue: :environment do
      label = ENV["LABEL"]
      abort "LABEL=... を指定してください。例: bin/rails ms:admin:issue LABEL=ci" if label.blank?
      plain = AdminKey.issue!(label: label)
      print_key("ADMIN KEY", plain, label: label)
    end

    desc "管理キーを失効させる。LABEL=... または ID=... で指定。"
    task revoke: :environment do
      label = ENV["LABEL"]
      id = ENV["ID"]
      abort "LABEL=... または ID=... を指定してください" if label.blank? && id.blank?

      scope = AdminKey.active
      scope = scope.where(label: label) if label.present?
      scope = scope.where(id: id) if id.present?

      count = scope.count
      abort "該当する有効な管理キーがありません" if count.zero?

      scope.find_each(&:revoke!)
      puts "[ms:admin:revoke] #{count} 件の管理キーを失効させました"
    end

    desc "有効な管理キーを一覧"
    task list: :environment do
      keys = AdminKey.active.order(:created_at)
      if keys.empty?
        puts "(有効な管理キーなし)"
        next
      end
      printf "%-6s  %-30s  %-20s  %s\n", "ID", "LABEL", "CREATED", "LAST USED"
      keys.each do |k|
        printf "%-6d  %-30s  %-20s  %s\n",
          k.id,
          k.label || "(no label)",
          k.created_at.strftime("%Y-%m-%d %H:%M"),
          k.last_used_at&.strftime("%Y-%m-%d %H:%M") || "-"
      end
    end
  end

  namespace :device do
    desc "デバイスを登録してデバイスキーを発行する。DEVICE_NAME=... 必須。DEVICE_SLUG=... と CAPABILITIES='{...}' は任意。"
    task register: :environment do
      name = ENV["DEVICE_NAME"]
      abort "DEVICE_NAME=... を指定してください。例: bin/rails ms:device:register DEVICE_NAME=stackchan-001" if name.blank?

      slug = ENV.fetch("DEVICE_SLUG") { name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-+|-+$/, "") }
      caps = parse_capabilities(ENV["CAPABILITIES"])

      if Device.exists?(slug: slug)
        abort "[ms:device:register] slug '#{slug}' は既に使用されています。SLUG=... で別名を指定するか、ms:device:rotate_key でキー再発行してください。"
      end

      device = Device.create!(name: name, slug: slug, capabilities: caps)
      plain = DeviceKey.issue!(device: device, label: ENV["KEY_LABEL"] || "primary")

      puts "[ms:device:register] 登録完了"
      puts "  device.slug         = #{device.slug}"
      puts "  device.name         = #{device.name}"
      puts "  device.capabilities = #{device.capabilities.inspect}"
      print_key("DEVICE KEY", plain, label: "primary")
    end

    desc "デバイスのキーをローテーション（既存を失効、新規発行）。DEVICE_SLUG=... 必須。"
    task rotate_key: :environment do
      slug = ENV["DEVICE_SLUG"]
      abort "DEVICE_SLUG=... を指定してください" if slug.blank?

      device = Device.find_by(slug: slug)
      abort "[ms:device:rotate_key] slug '#{slug}' のデバイスが見つかりません" unless device

      revoked = device.device_keys.active.count
      device.device_keys.active.find_each(&:revoke!)
      plain = DeviceKey.issue!(device: device, label: ENV["KEY_LABEL"] || "rotated")

      puts "[ms:device:rotate_key] #{revoked} 件の既存キーを失効、新規キー発行"
      print_key("DEVICE KEY", plain, label: "rotated")
    end

    desc "登録済みデバイス一覧"
    task list: :environment do
      devices = Device.order(:slug)
      if devices.empty?
        puts "(登録済みデバイスなし)"
        next
      end
      printf "%-30s  %-30s  %-15s  %s\n", "SLUG", "NAME", "ACTIVE KEYS", "LAST HEARTBEAT"
      devices.each do |d|
        printf "%-30s  %-30s  %-15d  %s\n",
          d.slug,
          d.name,
          d.device_keys.active.count,
          d.last_heartbeat_at&.strftime("%Y-%m-%d %H:%M") || "-"
      end
    end

    desc "デバイスを削除（紐付くキーも全失効）。DEVICE_SLUG=... 必須。"
    task remove: :environment do
      slug = ENV["DEVICE_SLUG"]
      abort "DEVICE_SLUG=... を指定してください" if slug.blank?
      device = Device.find_by(slug: slug)
      abort "slug '#{slug}' のデバイスが見つかりません" unless device

      device.destroy!
      puts "[ms:device:remove] '#{slug}' を削除しました"
    end
  end

  # --- helpers ---

  def parse_capabilities(json_str)
    return {} if json_str.blank?
    JSON.parse(json_str)
  rescue JSON::ParserError => e
    abort "CAPABILITIES の JSON パースに失敗: #{e.message}"
  end

  def print_key(kind, plain, label:)
    puts ""
    puts "  #{kind} (label=#{label})"
    puts "    #{plain}"
    puts ""
    puts "  ⚠️  この平文キーは今だけ表示されます。安全な場所に保管してください。"
    puts "  ⚠️  DBにはハッシュのみが保存されており、再表示はできません。"
    puts ""
  end
end
