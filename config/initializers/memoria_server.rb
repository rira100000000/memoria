require_relative "../../lib/memoria_server"

Rails.logger.info "[MemoriaServer] Redis: #{MemoriaServer::RedisClient.url}"

# リポジトリの外に置いた個人的なプラグイン（MEMORIA_PLUGIN_PATHS）を読み込む。
# プラグインがアプリのクラスを参照できるよう、初期化の完了後に読む
Rails.application.config.after_initialize do
  MemoriaServer::Plugin.load_paths!
end
