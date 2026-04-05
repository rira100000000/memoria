require "yaml"

# キャラクター設定を外部ファイルから読み込む
# 1. MEMORIA_CONFIG環境変数で指定されたパス
# 2. なければ環境変数からの最小設定（個人情報なし）
#
# 設定ファイル（memoria_config.yml）はhal-memory等のprivateリポジトリで管理し、
# publicリポジトリにはキャラクター名やsystem_promptを含めない

config_path = ENV["MEMORIA_CONFIG"]
config_path ||= Dir.glob(File.expand_path("~/**/memoria_config.yml")).first

if config_path && File.exist?(config_path)
  puts "Loading config from: #{config_path}"
  config = YAML.safe_load(File.read(config_path), permitted_classes: [Date, Time])

  user_email = config.dig("user", "email") || ENV.fetch("SEED_USER_EMAIL", "user@example.com")
  user = User.find_or_create_by!(email: user_email)
  puts "User: #{user.email} (token: #{user.api_token})"

  (config["characters"] || {}).each do |key, char_config|
    char = user.characters.find_or_create_by!(name: char_config["name"]) do |c|
      c.system_prompt = char_config["system_prompt"]
    end

    char.update!(pet_config: char_config["pet_config"]) if char_config["pet_config"]
    char.update!(thinking_loop_enabled: char_config["thinking_loop_enabled"]) if char_config.key?("thinking_loop_enabled")

    puts "Character: #{char.name} (vault: #{char.vault_path})"

    channel_env = case key
    when "main" then "DISCORD_CHANNEL_ID"
    when "test" then "DISCORD_TEST_CHANNEL_ID"
    end

    if channel_env && ENV[channel_env].present?
      binding = ChannelBinding.find_or_create_by!(platform: "discord", channel_id: ENV[channel_env]) do |b|
        b.character = char
      end
      puts "  ChannelBinding: Discord ##{binding.channel_id} → #{char.name}"
    end
  end
else
  puts "No config file found. Using environment variables for minimal setup."

  user = User.find_or_create_by!(email: ENV.fetch("SEED_USER_EMAIL", "user@example.com"))
  puts "User: #{user.email} (token: #{user.api_token})"

  char = user.characters.find_or_create_by!(name: ENV.fetch("SEED_MAIN_CHARACTER_NAME", "アシスタント")) do |c|
    c.system_prompt = ENV.fetch("SEED_MAIN_CHARACTER_PROMPT", "あなたは親切なアシスタントです。")
  end
  puts "Character: #{char.name} (vault: #{char.vault_path})"

  if ENV["DISCORD_CHANNEL_ID"].present?
    ChannelBinding.find_or_create_by!(platform: "discord", channel_id: ENV["DISCORD_CHANNEL_ID"]) do |b|
      b.character = char
    end
  end
end
