require "net/http"
require "zip"
require "stringio"

module Reading
  class TextFetcher
    TIMEOUT = 15

    # CSVの行ハッシュからテキストを取得
    # @param work_row [Hash] CSVの行（"テキストフ��イルURL"キーを含��）
    # @return [String, nil] UTF-8テキスト or nil
    def self.fetch(work_row)
      url = work_row["テキストファイルURL"]
      return nil unless url.present?

      zip_data = download(url)
      return nil unless zip_data

      raw_text = extract_text_from_zip(zip_data)
      return nil unless raw_text

      text = encode_to_utf8(raw_text)
      strip_aozora_markup(text)
    rescue => e
      Rails.logger.error("[TextFetcher] Failed for #{work_row["作品ID"]}: #{e.message}")
      nil
    end

    class << self
      private

      def download(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        response = http.get(uri.request_uri)
        return nil unless response.code == "200"
        response.body.force_encoding("ASCII-8BIT")
      rescue => e
        Rails.logger.error("[TextFetcher] Download failed: #{e.message}")
        nil
      end

      def extract_text_from_zip(zip_data)
        result = nil
        io = StringIO.new(zip_data)
        Zip::File.open_buffer(io) do |zip_file|
          txt_entry = zip_file.find { |entry| entry.name.end_with?(".txt") }
          result = txt_entry&.get_input_stream&.read
        end
        result
      end

      def encode_to_utf8(raw)
        # 青空文庫はShift_JIS（Windows-31Jスーパーセット）
        raw.force_encoding("Windows-31J").encode("UTF-8", invalid: :replace, undef: :replace)
      end

      def strip_aozora_markup(text)
        # 改行を統一
        text = text.gsub("\r\n", "\n")

        # ヘッダー（凡例ブロック）除去: 「---」で囲まれた記号説明部分
        text = text.sub(/\A.*?-{5,}\n.*?-{5,}\n/m, "")

        text = text.gsub(/《.+?》/, "")          # ルビ除去
        text = text.gsub(/［＃.+?］/, "")        # 注記除去
        text = text.gsub(/｜/, "")                # ルビ開始記号除去

        # 底本情報以降を除去（「底本：」or「底本:」で始まる行以降）
        if (idx = text.index(/^底本[：:]/, 0))
          text = text[0...idx]
        end

        text.strip
      end
    end
  end
end
