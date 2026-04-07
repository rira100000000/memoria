require "rails_helper"
require "zip"

RSpec.describe Reading::TextFetcher do
  describe ".fetch" do
    let(:sample_text) { "吾輩は猫である。名前はまだ無い。" }
    let(:sjis_text) { sample_text.encode("Windows-31J") }

    let(:work_row) do
      { "作品ID" => "123", "テキストファイルURL" => "https://www.aozora.gr.jp/cards/000148/files/789_ruby_5968.zip" }
    end

    def build_zip_with_text(text_content)
      buffer = StringIO.new
      buffer.set_encoding("ASCII-8BIT")
      Zip::OutputStream.write_buffer(buffer) do |zip|
        zip.put_next_entry("789_ruby_5968.txt")
        zip.write(text_content)
      end
      buffer.string
    end

    it "downloads zip, extracts text, and converts to UTF-8" do
      zip_data = build_zip_with_text(sjis_text)

      stub_request(:get, work_row["テキストファイルURL"])
        .to_return(status: 200, body: zip_data)

      result = described_class.fetch(work_row)
      expect(result).to include("吾輩は猫である")
    end

    it "strips aozora markup" do
      marked_up = "吾輩《わがはい》は猫｜である。［＃太字］名前はまだ無い。"
      zip_data = build_zip_with_text(marked_up.encode("Windows-31J"))

      stub_request(:get, work_row["テキストファイルURL"])
        .to_return(status: 200, body: zip_data)

      result = described_class.fetch(work_row)
      expect(result).to eq("吾輩は猫である。名前はまだ無い。")
    end

    it "strips bottom-source boilerplate" do
      with_source = "本文。\n底本：「太宰治全集」\n出版社情報"
      zip_data = build_zip_with_text(with_source.encode("Windows-31J"))

      stub_request(:get, work_row["テキストファイルURL"])
        .to_return(status: 200, body: zip_data)

      result = described_class.fetch(work_row)
      expect(result).to eq("本文。")
    end

    it "returns nil when URL is blank" do
      result = described_class.fetch({ "作品ID" => "1", "テキストファイルURL" => nil })
      expect(result).to be_nil
    end

    it "returns nil on HTTP error" do
      stub_request(:get, work_row["テキストファイルURL"])
        .to_return(status: 404)

      result = described_class.fetch(work_row)
      expect(result).to be_nil
    end

    it "returns nil when zip contains no .txt file" do
      buffer = StringIO.new
      Zip::OutputStream.write_buffer(buffer) do |zip|
        zip.put_next_entry("readme.html")
        zip.write("<html></html>")
      end

      stub_request(:get, work_row["テキストファイルURL"])
        .to_return(status: 200, body: buffer.string)

      result = described_class.fetch(work_row)
      expect(result).to be_nil
    end
  end
end
