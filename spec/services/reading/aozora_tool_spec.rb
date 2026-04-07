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

  let(:boundaries) { [{ "end" => 800, "label" => "前半" }, { "end" => sample_text.length, "label" => "後半" }] }

  before do
    allow(Reading::AozoraCatalog).to receive(:random_pick).and_return(work_row)
    allow(Reading::TextFetcher).to receive(:fetch).and_return(sample_text)
    allow(Reading::ChunkPreprocessor).to receive(:call).and_return(boundaries)
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
        allow(Reading::ChunkPreprocessor).to receive(:call).and_return([{ "end" => short_text.length, "label" => "全文" }])

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
      it "returns next chunk based on chunk_boundaries" do
        create(:reading_progress,
          character: character,
          work_id: "1567",
          cached_text: sample_text,
          current_position: 100,
          total_length: sample_text.length,
          chunk_boundaries: [{ "end" => 800, "label" => "前半" }, { "end" => sample_text.length, "label" => "後半" }].to_json,
          status: "reading")

        result = described_class.execute(action: "continue", character: character)
        expect(result[:chunk]).to be_present
        expect(result[:chunk_label]).to eq("前半")
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
          chunk_boundaries: [{ "end" => 7, "label" => "全文" }].to_json,
          status: "reading")

        result = described_class.execute(action: "continue", character: character)
        expect(result[:finished]).to be true
        expect(ReadingProgress.last.status).to eq("completed")
      end

      it "falls back to remaining text when no chunk_boundaries" do
        create(:reading_progress,
          character: character,
          work_id: "1567",
          cached_text: "テスト用のテキスト。",
          current_position: 0,
          total_length: 10,
          chunk_boundaries: nil,
          status: "reading")

        result = described_class.execute(action: "continue", character: character)
        expect(result[:finished]).to be true
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

end
