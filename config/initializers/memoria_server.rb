require_relative "../../lib/memoria_server"

Rails.logger.info "[MemoriaServer] Redis: #{MemoriaServer::RedisClient.url}"
