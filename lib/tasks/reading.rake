namespace :reading do
  desc "キャラクターの読書ログを表示 (CHAR_ID=1)"
  task log: :environment do
    char_id = ENV.fetch("CHAR_ID", 1).to_i
    character = Character.find(char_id)

    rp = character.current_reading
    rp ||= ReadingProgress.where(character: character).order(updated_at: :desc).first
    abort "読書記録がありません" unless rp

    puts "#{rp.author}「#{rp.title}」#{rp.current_position}/#{rp.total_length}字 [#{rp.status}]"
    if rp.parsed_chunk_boundaries.any?
      puts "チャンク: #{rp.parsed_chunk_boundaries.size}分割"
    end
    puts ""

    companion_name = character.reading_companion&.name || Reading::ReadingCompanion::NAME

    rp.parsed_notes.each do |entry|
      case entry["type"]
      when "narration"
        puts "📖 #{entry["text"]}"
      when "dialogue"
        if entry["speaker"] == "hal"
          puts "🌸 #{character.name}: #{entry["text"]}"
        else
          puts "🔮 #{companion_name}: #{entry["text"]}"
        end
      end
      puts ""
    end
  end
end
