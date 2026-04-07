require "rails_helper"

RSpec.describe Reading::AozoraTool do
  let(:character) { create(:character, reading_enabled: true) }

  let(:work_row) do
    {
      "作品ID" => "1567",
      "作品名" => "走れメロス",
      "姓" => "太宰",
      "名" => "治",
      "底本名1" => "太宰治全集",
      "入力者" => "テスト太郎",
      "テキストファイルURL" => "https://example.com/test.zip",
    }
  end

  let(:sample_text) { "メロスは激怒した。" * 200 } # ~1800 chars

  before do
    allow(Reading::AozoraCatalog).to receive(:random_pick).and_return(work_row)
    allow(Reading::TextFetcher).to receive(:fetch).and_return(sample_text)
  end

  describe ".definition" do
    it "returns functionDeclarations with read_aozora" do
      defn = described_class.definition
      names = defn[:functionDeclarations].map { |f| f[:name] }
      expect(names).to include("read_aozora")
    end
  end

  describe ".execute" do
    context "discover" do
      it "creates a reading progress and returns first chunk" do
        result = described_class.execute(action: "discover", character: character)

        expect(result[:title]).to eq("走れメロス")
        expect(result[:author]).to eq("太宰治")
        expect(result[:chunk]).to be_present
        expect(result[:progress]).to include("/")
        expect(result[:source]).to include("底本")

        expect(ReadingProgress.count).to eq(1)
        rp = ReadingProgress.last
        expect(rp.work_id).to eq("1567")
        expect(rp.cached_text).to eq(sample_text)
        expect(result[:reading_progress_id]).to eq(rp.id)
      end

      it "marks short works as completed immediately" do
        short_text = "短い話。おわり。"
        allow(Reading::TextFetcher).to receive(:fetch).and_return(short_text)

        result = described_class.execute(action: "discover", character: character)
        expect(result[:finished]).to be true
        expect(ReadingProgress.last.status).to eq("completed")
      end

      it "returns error when no works found" do
        allow(Reading::AozoraCatalog).to receive(:random_pick).and_return(nil)
        result = described_class.execute(action: "discover", character: character)
        expect(result[:error]).to be_present
      end

      it "returns error when text fetch fails" do
        allow(Reading::TextFetcher).to receive(:fetch).and_return(nil)
        result = described_class.execute(action: "discover", character: character)
        expect(result[:error]).to include("テキスト")
      end

      it "filters by genre" do
        described_class.execute(action: "discover", genre: "太宰", character: character)
        expect(Reading::AozoraCatalog).to have_received(:random_pick).with(genre: "太宰", exclude_ids: [])
      end
    end

    context "continue" do
      it "returns next chunk from cached text" do
        create(:reading_progress,
          character: character,
          work_id: "1567",
          cached_text: sample_text,
          current_position: 100,
          total_length: sample_text.length,
          status: "reading")

        result = described_class.execute(action: "continue", character: character)
        expect(result[:chunk]).to be_present
        expect(result[:title]).to eq("走れメロス")
      end

      it "returns error when no reading in progress" do
        result = described_class.execute(action: "continue", character: character)
        expect(result[:error]).to include("読みかけ")
      end

      it "marks as completed when reaching end" do
        create(:reading_progress,
          character: character,
          work_id: "1567",
          cached_text: "短いテキスト。",
          current_position: 0,
          total_length: 7,
          status: "reading")

        result = described_class.execute(action: "continue", character: character)
        expect(result[:finished]).to be true
        expect(ReadingProgress.last.status).to eq("completed")
      end
    end

    context "search" do
      it "returns matching works" do
        allow(Reading::AozoraCatalog).to receive(:search)
          .with("太宰").and_return([{ work_id: "1567", title: "走れメロス", author: "太宰治" }])

        result = described_class.execute(action: "search", query: "太宰", character: character)
        expect(result[:results]).to be_present
        expect(result[:results].first[:title]).to eq("走れメロス")
      end

      it "returns error when query is blank" do
        result = described_class.execute(action: "search", query: "", character: character)
        expect(result[:error]).to include("検索クエリ")
      end
    end

    context "read" do
      it "starts reading a specific work by ID" do
        allow(Reading::AozoraCatalog).to receive(:find_by_id)
          .with("1567").and_return(work_row)

        result = described_class.execute(action: "read", work_id: "1567", character: character)
        expect(result[:title]).to eq("走れメロス")
        expect(result[:chunk]).to be_present
        expect(ReadingProgress.last.work_id).to eq("1567")
      end

      it "returns error when work_id not found" do
        allow(Reading::AozoraCatalog).to receive(:find_by_id).and_return(nil)

        result = described_class.execute(action: "read", work_id: "99999", character: character)
        expect(result[:error]).to include("見つかりません")
      end

      it "returns error when work already read" do
        create(:reading_progress, character: character, work_id: "1567")

        result = described_class.execute(action: "read", work_id: "1567", character: character)
        expect(result[:error]).to include("既に読んだ")
      end
    end

    context "daily limit" do
      it "returns error when daily limit reached" do
        Reading::AozoraTool::MAX_DAILY_SESSIONS.times do |i|
          create(:reading_progress,
            character: character,
            work_id: "#{i}",
            updated_at: Time.current)
        end

        result = described_class.execute(action: "discover", character: character)
        expect(result[:error]).to include("上限")
      end

      it "does not count yesterday's sessions" do
        create(:reading_progress,
          character: character,
          work_id: "old",
          updated_at: 1.day.ago)

        result = described_class.execute(action: "discover", character: character)
        expect(result[:error]).to be_nil
      end

      it "allows search even when daily limit reached" do
        Reading::AozoraTool::MAX_DAILY_SESSIONS.times do |i|
          create(:reading_progress, character: character, work_id: "#{i}", updated_at: Time.current)
        end

        allow(Reading::AozoraCatalog).to receive(:search).and_return([])
        result = described_class.execute(action: "search", query: "太宰", character: character)
        expect(result[:error]).to be_nil
      end
    end
  end

  describe ".find_chunk_end" do
    it "splits at 。 near target" do
      target = described_class::CHUNK_TARGET
      text = "あ" * (target - 100) + "。" + "い" * 500
      result = described_class.send(:find_chunk_end, text, 0)
      expect(text[result - 1]).to eq("。")
    end

    it "splits at newline if no 。 found" do
      target = described_class::CHUNK_TARGET
      text = "あ" * (target - 100) + "\n" + "い" * 500
      result = described_class.send(:find_chunk_end, text, 0)
      expect(result).to eq(target - 100 + 1)
    end

    it "falls back to target when no delimiter found" do
      text = "あ" * 5000
      result = described_class.send(:find_chunk_end, text, 0)
      expect(result).to eq(Reading::AozoraTool::CHUNK_TARGET)
    end

    it "returns text length if target exceeds text" do
      text = "短い文章。"
      result = described_class.send(:find_chunk_end, text, 0)
      expect(result).to eq(text.length)
    end
  end
end
