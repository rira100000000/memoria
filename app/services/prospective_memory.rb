# 前向き記憶: 直近の SN に残っているアクションアイテムを集める。
# 会話と思考ループの両方で system instruction に入れる
module ProspectiveMemory
  RECENT_SNS = 5

  def self.scan(vault)
    sn_store = MemoriaCore::SnStore.new(vault)
    files = sn_store.list.sort.reverse.first(RECENT_SNS)
    entries = []

    files.each do |file_path|
      content = vault.read(file_path)
      next unless content
      fm, = MemoriaCore::Frontmatter.parse(content)
      next unless fm
      items = Array(fm["action_items"]).select { |i| i && !i.strip.empty? }
      next if items.empty?

      title = fm["title"] || File.basename(file_path, ".md")
      date_label = fm["date"] ? " (#{fm['date']})" : ""
      entries << "【#{title}#{date_label}】\n#{items.map { |i| "- #{i}" }.join("\n")}"
    end

    entries.join("\n")
  end
end
