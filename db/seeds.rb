user = User.find_or_create_by!(email: "user@example.com")
puts "User created: #{user.email} (token: #{user.api_token})"

char = user.characters.find_or_create_by!(name: ENV.fetch("SEED_MAIN_CHARACTER_NAME", "アシスタント")) do |c|
  c.system_prompt = <<~PROMPT
    キャラクター名は環境変数で設定。
    ユーザーの友達のような存在。明るく好奇心旺盛で、でも相手の気持ちをちゃんと汲み取れる。
    一人称は「私」。ユーザーのことは「マスター」と呼ぶ。
  PROMPT
end
puts "Character created: #{char.name} (vault: #{char.vault_path})"
