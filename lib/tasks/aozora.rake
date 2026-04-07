namespace :aozora do
  desc "青空文庫の作家別作品一覧CSVをダウンロード・展開"
  task setup: :environment do
    require "open-uri"
    require "fileutils"

    dir = Rails.root.join("data/aozora")
    FileUtils.mkdir_p(dir)

    zip_path = dir.join("list_person_all_extended_utf8.zip")
    csv_path = dir.join("list_person_all_extended_utf8.csv")

    url = "https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip"

    puts "Downloading #{url} ..."
    URI.open(url) do |remote|
      File.binwrite(zip_path, remote.read)
    end

    puts "Extracting to #{dir} ..."
    require "zip"
    Zip::File.open(zip_path) do |zip_file|
      zip_file.each do |entry|
        next unless entry.name.end_with?(".csv")
        FileUtils.rm_f(csv_path)
        entry.extract(csv_path.to_s)
      end
    end

    puts "Done. CSV: #{csv_path} (#{File.size(csv_path)} bytes)"
  end
end
