class ReadingProgress < ApplicationRecord
  belongs_to :character

  STATUSES = %w[reading completed abandoned].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :work_id, uniqueness: { scope: :character_id }

  scope :reading, -> { where(status: "reading") }
  scope :completed, -> { where(status: "completed") }

  def complete!
    update!(status: "completed", cached_text: nil)
  end

  def abandon!
    update!(status: "abandoned", cached_text: nil)
  end

  # --- チャンク分割 ---

  def parsed_chunk_boundaries
    return [] if chunk_boundaries.blank?
    JSON.parse(chunk_boundaries)
  rescue JSON::ParserError
    []
  end

  def next_chunk_end(from_position)
    boundaries = parsed_chunk_boundaries
    return nil if boundaries.empty?
    boundary = boundaries.find { |b| b["end"] > from_position }
    boundary ? [boundary["end"], boundary["label"]] : nil
  end

  # --- 読書ノート ---

  def append_note(note_text, chunk_range: nil)
    append_reading_log([{
      "type" => "dialogue",
      "speaker" => "hal",
      "text" => note_text,
      "chunk_range" => chunk_range,
    }])
  end

  def append_reading_log(entries)
    all = parsed_notes
    entries.each do |entry|
      all << entry.merge("timestamp" => Time.current.iso8601)
    end
    update!(reading_notes: all.to_json)
  end

  def parsed_notes
    return [] if reading_notes.blank?
    JSON.parse(reading_notes)
  rescue JSON::ParserError
    []
  end

  def combined_notes_text
    parsed_notes.map { |entry|
      if entry["type"] == "narration"
        "【原文】#{entry["text"]&.slice(0, 200)}…"
      elsif entry["type"] == "dialogue"
        speaker = entry["speaker"] == "hal" ? character.name : Reading::ReadingCompanion::NAME
        "#{speaker}: #{entry["text"]}"
      else
        # 旧形式との互換
        range = entry["chunk_range"] ? "(#{entry["chunk_range"]}字目) " : ""
        "#{range}#{entry["note"] || entry["text"]}"
      end
    }.join("\n\n")
  end
end
