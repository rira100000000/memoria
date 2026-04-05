require_relative "../config/environment"

character = Character.first
puts "Character: #{character.name}"
puts "Time: #{Time.current.strftime('%H:%M:%S %Z')}"

worker = ThinkingLoopWorker.new
worker.perform(character.id)

puts "Done!"
