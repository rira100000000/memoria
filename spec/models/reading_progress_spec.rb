require "rails_helper"

RSpec.describe ReadingProgress, type: :model do
  describe "validations" do
    it "validates status inclusion" do
      rp = build(:reading_progress, status: "invalid")
      expect(rp).not_to be_valid
    end

    it "validates work_id uniqueness per character" do
      character = create(:character)
      create(:reading_progress, character: character, work_id: "123")
      duplicate = build(:reading_progress, character: character, work_id: "123")
      expect(duplicate).not_to be_valid
    end

    it "allows same work_id for different characters" do
      rp1 = create(:reading_progress, work_id: "123")
      rp2 = build(:reading_progress, work_id: "123")
      expect(rp2).to be_valid
    end
  end

  describe "scopes" do
    it ".reading returns only reading status" do
      reading = create(:reading_progress, status: "reading")
      create(:reading_progress, status: "completed")
      expect(ReadingProgress.reading).to eq([reading])
    end

    it ".completed returns only completed status" do
      create(:reading_progress, status: "reading")
      completed = create(:reading_progress, status: "completed")
      expect(ReadingProgress.completed).to eq([completed])
    end
  end

  describe "#complete!" do
    it "sets status to completed and clears cached_text" do
      rp = create(:reading_progress, status: "reading", cached_text: "some text")
      rp.complete!
      expect(rp.reload.status).to eq("completed")
      expect(rp.cached_text).to be_nil
    end
  end

  describe "#abandon!" do
    it "sets status to abandoned and clears cached_text" do
      rp = create(:reading_progress, status: "reading", cached_text: "some text")
      rp.abandon!
      expect(rp.reload.status).to eq("abandoned")
      expect(rp.cached_text).to be_nil
    end
  end

  describe "#append_note" do
    it "appends as dialogue entry" do
      rp = create(:reading_progress)
      rp.append_note("最初の感想", chunk_range: "800")
      expect(rp.parsed_notes.size).to eq(1)
      expect(rp.parsed_notes.first["type"]).to eq("dialogue")
      expect(rp.parsed_notes.first["speaker"]).to eq("hal")
      expect(rp.parsed_notes.first["text"]).to eq("最初の感想")
    end
  end

  describe "#append_reading_log" do
    it "appends structured entries" do
      rp = create(:reading_progress)
      rp.append_reading_log([
        { "type" => "narration", "text" => "原文テキスト", "chunk_range" => "800" },
        { "type" => "dialogue", "speaker" => "hal", "text" => "感想" },
        { "type" => "dialogue", "speaker" => "companion", "text" => "いいね" },
      ])
      expect(rp.parsed_notes.size).to eq(3)
      expect(rp.parsed_notes[0]["type"]).to eq("narration")
      expect(rp.parsed_notes[1]["speaker"]).to eq("hal")
      expect(rp.parsed_notes[2]["speaker"]).to eq("companion")
    end

    it "appends to existing entries" do
      rp = create(:reading_progress, reading_notes: [{ "type" => "dialogue", "speaker" => "hal", "text" => "既存" }].to_json)
      rp.append_reading_log([{ "type" => "dialogue", "speaker" => "companion", "text" => "追加" }])
      expect(rp.parsed_notes.size).to eq(2)
    end
  end

  describe "#parsed_notes" do
    it "returns empty array for nil" do
      rp = build(:reading_progress, reading_notes: nil)
      expect(rp.parsed_notes).to eq([])
    end

    it "returns empty array for invalid JSON" do
      rp = build(:reading_progress, reading_notes: "not json")
      expect(rp.parsed_notes).to eq([])
    end
  end

  describe "#combined_notes_text" do
    it "formats new structured entries" do
      notes = [
        { "type" => "narration", "text" => "メロスは激怒した。" },
        { "type" => "dialogue", "speaker" => "hal", "text" => "すごい出だし！" },
        { "type" => "dialogue", "speaker" => "companion", "text" => "どこが気になった？" },
      ]
      rp = create(:reading_progress, reading_notes: notes.to_json)
      text = rp.combined_notes_text
      expect(text).to include("【原文】メロスは激怒した。")
      expect(text).to include("#{rp.character.name}: すごい出だし！")
      expect(text).to include("トート: どこが気になった？")
    end

    it "handles legacy format" do
      notes = [
        { "chunk_range" => "800", "note" => "旧形式の感想" },
      ]
      rp = build(:reading_progress, reading_notes: notes.to_json)
      text = rp.combined_notes_text
      expect(text).to include("(800字目) 旧形式の感想")
    end
  end
end
