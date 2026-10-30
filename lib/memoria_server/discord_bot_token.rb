module MemoriaServer
  # bot の鍵の置き場所。MEMORIA_BOT_TOKEN（値）か、MEMORIA_BOT_TOKEN_FILE（ファイル。権限は本人だけに）から読む。
  # どちらもなければ nil（その場合、bot の入口は誰も通さない）。値は、ログにも出力にも出さない
  module DiscordBotToken
    module_function

    def current(env = ENV)
      value = env["MEMORIA_BOT_TOKEN"].to_s.strip
      return value unless value.empty?

      path = env["MEMORIA_BOT_TOKEN_FILE"].to_s.strip
      return nil if path.empty? || !File.file?(path)

      File.read(path).strip.then { |text| text.empty? ? nil : text }
    end
  end
end
