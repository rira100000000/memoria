require "redis"

module MemoriaServer
  # MS が pub/sub に使う Redis 接続を一元管理する。
  # 接続先は `MS_REDIS_URL` または `REDIS_URL` 環境変数。デフォルトは `redis://localhost:6379/0`。
  module RedisClient
    DEFAULT_URL = "redis://localhost:6379/0".freeze

    class << self
      # publish 用：スレッドセーフ前提のシングルトン接続。
      def publisher
        @publisher ||= ::Redis.new(url: url)
      end

      # subscribe 用：呼び出しごとに新規接続を返す（subscribe はブロッキング）。
      def new_subscriber
        ::Redis.new(url: url)
      end

      def url
        ENV["MS_REDIS_URL"] || ENV["REDIS_URL"] || DEFAULT_URL
      end

      def reset!
        @publisher&.close
        @publisher = nil
      end
    end
  end
end
