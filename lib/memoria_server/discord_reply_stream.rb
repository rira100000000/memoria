require "json"

module MemoriaServer
  # Discord の1回の発言に対する返答を、サーバーから bot へイベント（DiscordProtocol）で流す。
  # 副作用（書き込み・待ち・スレッド）はここに閉じ込め、イベントの形と判断は DiscordProtocol が持つ。
  #
  # 契約:
  # - 事前条件: writer は write(String) を持つ。character は会話できるキャラクター
  # - 保証: 最初に accepted を書く（順番待ちより前）
  # - 保証: 返答のメッセージは、message イベントとして、出た順に書く
  # - 保証: 最後に、done か error を、ちょうど1つ書く。例外は呼び出し元に出さない（error イベントにする）
  # - 保証: 返答のあいだ、interval 秒おきに ping を書く。run が終われば止まる（スレッドを残さない）
  # - 保証: bot が切断しても、返答は最後まで作って会話の記録に残す（書き込みだけをやめる）
  class DiscordReplyStream
    DEFAULT_INTERVAL = 15

    # 書き込みを1つずつにして（行が混ざらないように）、切断されたら以後の書き込みをやめる
    class SafeWriter
      def initialize(writer)
        @writer = writer
        @mutex = Mutex.new
        @closed = false
      end

      def closed?
        @closed
      end

      def write(string)
        @mutex.synchronize do
          return false if @closed

          @writer.write(string)
          true
        end
      rescue IOError, SystemCallError, *disconnect_errors
        @closed = true
        false
      end

      private

      def disconnect_errors
        defined?(ActionController::Live::ClientDisconnected) ? [ ActionController::Live::ClientDisconnected ] : []
      end
    end

    def initialize(writer:, relay: DiscordRelay, interval: DEFAULT_INTERVAL)
      @writer = SafeWriter.new(writer)
      @relay = relay
      @interval = interval
    end

    def run(character:, text:, channel_name:, turn_wait: nil)
      @writer.write(DiscordProtocol.encode("accepted", character: character.name))
      stopper = Queue.new
      heartbeat = Thread.new do
        loop do
          break unless stopper.pop(timeout: @interval).nil?

          @writer.write(DiscordProtocol::PING)
        end
      end
      begin
        @relay.reply(character, text, channel_name: channel_name, turn_wait: turn_wait) do |message, last|
          @writer.write(DiscordProtocol.encode("message", text: message, last: last))
        end
        @writer.write(DiscordProtocol.encode("done"))
      rescue StandardError => e
        Rails.logger.error("[DiscordReplyStream] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        @writer.write(DiscordProtocol.encode("error", DiscordProtocol.error_for(e)))
      ensure
        stopper << :stop
        heartbeat.join
      end
    end
  end
end
