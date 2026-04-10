require_relative "../config/environment"

character = Character.first
puts "Character: #{character.name}"
puts "Time: #{Time.current.strftime('%H:%M:%S %Z')}"

ThinkingLoopJob.perform_now(character.id)

puts "Done!"
