module Reading
  class AozoraTool
    CHUNK_TARGET = 800
    CHUNK_SEARCH_RANGE = 200
    MAX_DAILY_SESSIONS = 2

    def self.definition
      {
        functionDeclarations: [{
          name: "read_aozora",
          description: "青空文庫の作品を読む。作品を検索したり、指定して読んだり、読みかけの続きを読める。",
          parameters: {
            type: "OBJECT",
            properties: {
              action: {
                type: "STRING",
                description: "'search'=作品を検索する, 'read'=作品IDを指定して読み始める, 'discover'=ランダムに新しい作品を選ぶ, 'continue'=読みかけの続きを読む",
              },
              query: {
                type: "STRING",
                description: "検索クエリ（作品名や著者名。searchで使用）",
              },
              work_id: {
                type: "STRING",
                description: "読みたい作品のID（readで使用。searchの結果から選ぶ）",
              },
              genre: {
                type: "STRING",
                description: "読みたいジャンルや著者の希望（discoverで使用、任意）",
              },
            },
            required: ["action"],
          },
        }],
      }
    end

    def self.execute(action:, genre: nil, query: nil, work_id: nil, character:)
      case action
      when "search"
        search_works(query)
      when "read"
        return { error: "今日の読書回数の上限（#{MAX_DAILY_SESSIONS}回）に達しました" } unless can_read_today?(character)
        read_work(character, work_id: work_id)
      when "discover"
        return { error: "今日の読書回数の上限（#{MAX_DAILY_SESSIONS}回）に達しました" } unless can_read_today?(character)
        discover(character, genre: genre)
      when "continue"
        return { error: "今日の読書回数の上限（#{MAX_DAILY_SESSIONS}回）に達しました" } unless can_read_today?(character)
        continue_reading(character)
      else
        { error: "Unknown action: #{action}" }
      end
    end

    def self.can_read_today?(character)
      ReadingProgress
        .where(character: character)
        .where("updated_at >= ?", Time.current.beginning_of_day)
        .select(:id).distinct.count < MAX_DAILY_SESSIONS
    end

    class << self
      private

      def search_works(query)
        return { error: "検索クエリを指定してください" } if query.blank?

        results = AozoraCatalog.search(query)
        if results.empty?
          { results: [], message: "「#{query}」に一致する作品が見つかりません" }
        else
          { results: results, message: "#{results.size}件見つかりました。readアクションでwork_idを指定して読めます。" }
        end
      end

      def read_work(character, work_id:)
        return { error: "作品IDを指定してください" } if work_id.blank?

        # 既に読んだ作品かチェック
        if ReadingProgress.exists?(character: character, work_id: work_id.to_s)
          return { error: "この作品は既に読んだことがあります（作品ID: #{work_id}）" }
        end

        work = AozoraCatalog.find_by_id(work_id)
        return { error: "作品ID #{work_id} が見つかりません" } unless work

        text = TextFetcher.fetch(work)
        return { error: "テキストの取得に失敗しました" } unless text

        chunk_end = find_chunk_end(text, 0)
        finished = chunk_end >= text.length

        progress = ReadingProgress.create!(
          character: character,
          work_id: work["作品ID"],
          title: work["作品名"],
          author: "#{work["姓"]}#{work["名"]}",
          source_info: build_source_info(work),
          cached_text: text,
          total_length: text.length,
          current_position: chunk_end,
          status: finished ? "completed" : "reading"
        )

        chunk = text[0...chunk_end]
        build_response(progress, chunk)
      end

      def discover(character, genre: nil)
        read_ids = ReadingProgress.where(character: character).pluck(:work_id)
        work = AozoraCatalog.random_pick(genre: genre, exclude_ids: read_ids)
        return { error: "条件に合う未読の作品が見つかりません" } unless work

        text = TextFetcher.fetch(work)
        return { error: "テキストの取得に失敗しました" } unless text

        chunk_end = find_chunk_end(text, 0)
        finished = chunk_end >= text.length

        progress = ReadingProgress.create!(
          character: character,
          work_id: work["作品ID"],
          title: work["作品名"],
          author: "#{work["姓"]}#{work["名"]}",
          source_info: build_source_info(work),
          cached_text: text,
          total_length: text.length,
          current_position: chunk_end,
          status: finished ? "completed" : "reading"
        )

        chunk = text[0...chunk_end]
        build_response(progress, chunk)
      end

      def continue_reading(character)
        progress = character.current_reading
        return { error: "読みかけの作品がありません" } unless progress
        return { error: "テキストデータが失われました" } unless progress.cached_text

        text = progress.cached_text
        start_pos = progress.current_position
        return build_response(progress, "") if start_pos >= text.length

        chunk_end = find_chunk_end(text, start_pos)
        finished = chunk_end >= text.length

        progress.update!(
          current_position: chunk_end,
          status: finished ? "completed" : "reading"
        )
        progress.update_column(:cached_text, nil) if finished

        chunk = text[start_pos...chunk_end]
        build_response(progress, chunk)
      end

      # 自然な区切り位置を探す
      # target付近の「。」→「\n」→ 強制切断 の優先順で探索
      def find_chunk_end(text, start_pos)
        target = start_pos + CHUNK_TARGET
        return text.length if target >= text.length

        search_start = [target - CHUNK_SEARCH_RANGE, start_pos].max
        search_end = [target + CHUNK_SEARCH_RANGE, text.length].min
        search_region = text[search_start...search_end]

        # 「。」で区切る（target以降で最初の句点を優先）
        relative_target = target - search_start
        after_region = search_region[relative_target..]
        if after_region && (pos = after_region.index("。"))
          return search_start + relative_target + pos + 1
        end
        before_region = search_region[0...relative_target]
        if before_region && (pos = before_region.rindex("。"))
          return search_start + pos + 1
        end

        # 「\n」で区切る
        if after_region && (pos = after_region.index("\n"))
          return search_start + relative_target + pos + 1
        end
        if before_region && (pos = before_region.rindex("\n"))
          return search_start + pos + 1
        end

        # 強制切断
        target
      end

      def build_response(progress, chunk)
        {
          title: progress.title,
          author: progress.author,
          chunk: chunk,
          progress: "#{progress.current_position}/#{progress.total_length}字",
          finished: progress.status == "completed",
          source: progress.source_info,
          reading_progress_id: progress.id,
        }
      end

      def build_source_info(work)
        parts = []
        parts << "底本: #{work["底本名1"]}" if work["底本名1"].present?
        parts << "入力: #{work["入力者"]}" if work["入力者"].present?
        parts.join(" / ")
      end
    end
  end
end
