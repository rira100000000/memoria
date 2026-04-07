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

  # --- 読書ノート ---

  def append_note(note_text, chunk_range: nil)
    entries = parsed_notes
    entries << {
      "chunk_range" => chunk_range,
      "note" => note_text,
      "timestamp" => Time.current.iso8601,
    }
    update!(reading_notes: entries.to_json)
  end

  def parsed_notes
    return [] if reading_notes.blank?
    JSON.parse(reading_notes)
  rescue JSON::ParserError
    []
  end

  def combined_notes_text
    parsed_notes.map { |entry|
      range = entry["chunk_range"] ? "(#{entry["chunk_range"]}字目) " : ""
      "#{range}#{entry["note"]}"
    }.join("\n\n---\n\n")
  end
end
