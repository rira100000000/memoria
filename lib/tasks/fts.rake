namespace :fts do
  desc "Rebuild the FTS5 index for one character (CHARACTER_ID=N) or all characters"
  task rebuild: :environment do
    character_id = ENV["CHARACTER_ID"]
    characters = character_id ? Character.where(id: character_id) : Character.all

    if characters.empty?
      puts "[fts:rebuild] no characters found"
      next
    end

    characters.each do |character|
      vault = MemoriaCore::VaultManager.new(character.vault_path)
      next unless Dir.exist?(character.vault_path)

      index = MemoriaCore::FtsIndex.new(vault)
      index.initialize!
      count = index.rebuild_from_vault!
      puts "[fts:rebuild] character=#{character.id} (#{character.name}) -> #{count} entries"
    end
  end
end
