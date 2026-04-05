# 環境変数またはデフォルト値からユーザー・キャラクターを作成
# 本番用の設定は.envで管理する

user_email = ENV.fetch("SEED_USER_EMAIL", "user@example.com")
user = User.find_or_create_by!(email: user_email)
puts "User created: #{user.email} (token: #{user.api_token})"

# --- メインキャラクター ---
main_name = ENV.fetch("SEED_MAIN_CHARACTER_NAME", "アシスタント")
main_prompt = ENV.fetch("SEED_MAIN_CHARACTER_PROMPT", "あなたは親切なアシスタントです。")

main_char = user.characters.find_or_create_by!(name: main_name) do |c|
  c.system_prompt = main_prompt
end
puts "Character: #{main_char.name} (vault: #{main_char.vault_path})"

if ENV["DISCORD_CHANNEL_ID"].present?
  binding = ChannelBinding.find_or_create_by!(platform: "discord", channel_id: ENV["DISCORD_CHANNEL_ID"]) do |b|
    b.character = main_char
  end
  puts "  ChannelBinding: Discord ##{binding.channel_id} → #{main_char.name}"
end

# --- テスト用キャラクター（任意） ---
if ENV["SEED_TEST_CHARACTER"].present?
  test_name = ENV.fetch("SEED_TEST_CHARACTER_NAME", "テスト")
  test_prompt = ENV.fetch("SEED_TEST_CHARACTER_PROMPT", "開発・動作確認用のキャラクター。淡々と正確に応答する。")

  test_char = user.characters.find_or_create_by!(name: test_name) do |c|
    c.system_prompt = test_prompt
  end
  puts "Character: #{test_char.name} (vault: #{test_char.vault_path})"

  if ENV["DISCORD_TEST_CHANNEL_ID"].present?
    binding = ChannelBinding.find_or_create_by!(platform: "discord", channel_id: ENV["DISCORD_TEST_CHANNEL_ID"]) do |b|
      b.character = test_char
    end
    puts "  ChannelBinding: Discord ##{binding.channel_id} → #{test_char.name}"
  end
end
