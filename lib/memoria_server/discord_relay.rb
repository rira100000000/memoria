module MemoriaServer
  # Discord のテキストを、アダプタの respond に渡して返答を受け取る。
  # Discord は連絡手段なので、プレゼンス（キャラがどのデバイスにいるか）は見ない（設計 3.4）。
  # アダプタのチャンクを、Discord に送るひとまとまりのメッセージに組み直す。
  module DiscordRelay
    module_function

    # @param channel_name [String] 会話の場所（例: "Discord #general"）。アダプタがプロンプトに使う
    # @yield [String, Boolean] Discord に送るメッセージと、それが最後の返答か。途中経過（「調べてみるね」など）はその場で渡す
    def reply(character, text, channel_name:)
      context = {
        character_id: character.id,
        character_name: character.name,
        channel: channel_name,
        platform: :discord,
        current_input: text,
        history: [],
        client_metadata: {},
        x_memoria: {},
      }

      buffer = +""
      flush = lambda { |last|
        message = buffer.strip
        buffer = +""
        yield message, last unless message.empty?
      }

      MemoriaServer.adapter.respond(text, context: context).each do |chunk|
        if chunk[:delta]
          buffer << chunk[:delta]
        elsif chunk[:message_break]
          flush.call(false)
        elsif chunk[:done]
          flush.call(true)
        end
      end
      flush.call(true)
    end
  end
end
