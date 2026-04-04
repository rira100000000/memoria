require "singleton"

# プロセス内でChatSessionをインメモリ管理するシングルトン
# Phase 2 で Redis/Sidekiq に置き換え予定
class ChatSessionStore
  include Singleton

  def initialize
    @sessions = {}
    @mutex = Mutex.new
  end

  def fetch(key)
    @mutex.synchronize do
      @sessions[key] ||= yield
    end
  end

  def get(key)
    @mutex.synchronize { @sessions[key] }
  end

  def delete(key)
    @mutex.synchronize { @sessions.delete(key) }
  end

  def clear!
    @mutex.synchronize { @sessions.clear }
  end
end
