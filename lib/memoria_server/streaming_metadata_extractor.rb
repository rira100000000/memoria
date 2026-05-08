require "json"

module MemoriaServer
  # LLM のストリーミング出力から `<x_memoria>{...}</x_memoria>` タグを抽出し、
  # 通常テキスト（delta）とメタデータ（metadata）に分離する state machine。
  #
  # 使い方:
  #   extractor = StreamingMetadataExtractor.new(capabilities: [Capabilities::EMOTION])
  #   extractor.feed("<x_memoria>{\"emotion\":\"happy\"}</x_memoria>こんにちは") do |kind, payload|
  #     case kind
  #     when :text     then puts "TEXT: #{payload}"
  #     when :metadata then puts "META: #{payload.inspect}"
  #     end
  #   end
  #   extractor.finalize { |kind, payload| ... }  # 残りバッファを flush
  #
  # 不正な JSON や閉じ忘れタグの場合は安全側に倒す（メタデータ無視・テキスト保持など）。
  class StreamingMetadataExtractor
    OPEN_TAG = "<x_memoria>".freeze
    CLOSE_TAG = "</x_memoria>".freeze

    def initialize(capabilities: [])
      @capabilities = capabilities
      @text_buffer = +""
      @meta_buffer = +""
      @in_metadata = false
    end

    # 新しいテキストチャンクを供給。state machine が次のような (:text, str) や
    # (:metadata, hash) を yield する。
    def feed(text, &block)
      return if text.nil?

      if @in_metadata
        @meta_buffer << text
      else
        @text_buffer << text
      end

      loop do
        if @in_metadata
          close_idx = @meta_buffer.index(CLOSE_TAG)
          break unless close_idx

          json_str = @meta_buffer[0...close_idx]
          metadata = parse_metadata(json_str)
          block.call(:metadata, metadata) if metadata.any?

          rest = @meta_buffer[(close_idx + CLOSE_TAG.length)..]
          @text_buffer = +(rest || "")
          @meta_buffer = +""
          @in_metadata = false
        else
          open_idx = @text_buffer.index(OPEN_TAG)
          if open_idx
            pre = @text_buffer[0...open_idx]
            block.call(:text, pre) if !pre.empty?

            after_open = @text_buffer[(open_idx + OPEN_TAG.length)..] || ""
            @meta_buffer = +after_open
            @text_buffer = +""
            @in_metadata = true
          else
            # 開きタグの prefix と一致する suffix を保持して安全な部分だけ emit
            holdback = max_partial_open_match(@text_buffer)
            safe_len = @text_buffer.length - holdback
            if safe_len > 0
              emit = @text_buffer[0, safe_len]
              block.call(:text, emit) if !emit.empty?
              @text_buffer = +(@text_buffer[safe_len..] || "")
            end
            break
          end
        end
      end
    end

    # ストリーム終了時に呼ぶ。残りバッファをフラッシュする。
    # 開きタグだけ来て閉じが来なかった場合、メタデータは破棄してテキストには出さない。
    def finalize(&block)
      if @in_metadata
        # 閉じ忘れ：メタ部分は破棄
        @meta_buffer = +""
        @in_metadata = false
      end

      if !@text_buffer.empty?
        block.call(:text, @text_buffer) if block
        @text_buffer = +""
      end
    end

    private

    # @text_buffer の末尾が OPEN_TAG の prefix と一致する最大長
    def max_partial_open_match(buffer)
      max = [buffer.length, OPEN_TAG.length - 1].min
      max.downto(1) do |len|
        suffix = buffer[-len, len]
        return len if OPEN_TAG.start_with?(suffix)
      end
      0
    end

    # JSON Hash → 各 capability の値を抜き出した Hash
    def parse_metadata(json_str)
      obj = JSON.parse(json_str.strip)
      return {} unless obj.is_a?(Hash)
      result = {}
      @capabilities.each do |cap|
        val = cap.parse_value(obj)
        result[cap.name] = val unless val.nil?
      end
      result
    rescue JSON::ParserError
      {}
    end
  end
end
