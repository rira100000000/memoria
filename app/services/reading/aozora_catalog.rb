module Reading
  class AozoraCatalog
    CSV_PATH = Rails.root.join("data/aozora/list_person_all_extended_utf8.csv")

    class << self
      def random_pick(genre: nil, exclude_ids: [])
        candidates = available_works
        candidates = filter_by_genre(candidates, genre) if genre.present?
        candidates = candidates.reject { |row| exclude_ids.include?(row["作品ID"]) }
        candidates.sample
      end

      def available_works
        catalog.select { |row| row["テキストファイルURL"].present? }
      end

      def search(query, limit: 10)
        return [] if query.blank?

        terms = query.split(/[\s　]+/).reject(&:blank?)
        available_works.select { |row|
          searchable = "#{row["作品名"]}#{row["姓"]}#{row["名"]}#{row["分類番号"]}"
          terms.all? { |term| searchable.include?(term) }
        }.first(limit).map { |row|
          {
            work_id: row["作品ID"],
            title: row["作品名"],
            author: "#{row["姓"]}#{row["名"]}",
          }
        }
      end

      def find_by_id(work_id)
        available_works.find { |row| row["作品ID"] == work_id.to_s }
      end

      def catalog
        current_mtime = csv_mtime
        return @catalog if @catalog && current_mtime && @catalog_mtime == current_mtime

        @catalog = load_csv
        @catalog_mtime = current_mtime
        @catalog
      end

      def reset!
        @catalog = nil
        @catalog_mtime = nil
      end

      private

      def load_csv
        unless File.exist?(CSV_PATH)
          Rails.logger.warn("[AozoraCatalog] CSV not found: #{CSV_PATH}. Run `rake aozora:setup` to download.")
          return []
        end

        require "csv"
        CSV.read(CSV_PATH, headers: true, encoding: "bom|utf-8").map(&:to_h)
      end

      def csv_mtime
        File.exist?(CSV_PATH) ? File.mtime(CSV_PATH) : nil
      end

      def filter_by_genre(candidates, genre)
        candidates.select { |row|
          row["姓"].to_s.include?(genre) ||
            row["名"].to_s.include?(genre) ||
            row["作品名"].to_s.include?(genre) ||
            row["分類番号"].to_s.include?(genre)
        }
      end
    end
  end
end
