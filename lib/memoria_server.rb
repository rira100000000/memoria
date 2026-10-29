module MemoriaServer
  class Error < StandardError; end

  # アダプタが respond/utter/action を呼んだ時、キャラクターがどのデバイスにもいない場合に raise
  class NoActiveDevice < Error; end

  # アダプタ contract 違反時に raise
  class ContractViolation < Error; end

  # アダプタが起床（wake）を実行しなかったときに raise する（予算切れ、LLM が使えない、起床に対応していない等）。
  # やり直しても同じ結果になる場合に使う。memoria は理由を予定の失敗として知らせ、やり直さない
  class WakeSkipped < Error; end

  class << self
    # アダプタ取得。環境変数 MS_ADAPTER により切替可能：
    #   - "memoria_core"（デフォルト）: 同梱リファレンス実装
    #   - "http": 外部HTTPアダプタへの薄いプロキシ。MS_ADAPTER_URL が必須
    #   - "<ClassName>": 任意の MemoriaServer::Adapter サブクラスを Object.const_get で解決
    # `MemoriaServer.adapter = MyAdapter.new` で実行時上書きも可能。
    def adapter
      @adapter ||= load_adapter_from_env
    end

    # キャラクターごとのディレクトリ（vault）を置く場所。User#vault_path → Character#vault_path の順に下る。
    # 記憶のアダプタも、プラグインも、キャラクターのファイルはこの下に置く
    def vault_root
      File.expand_path(ENV.fetch("VAULT_ROOT", "~/memoria-vaults"))
    end

    def adapter_kind
      ENV.fetch("MS_ADAPTER", "memoria_core").to_s
    end

    private

    def load_adapter_from_env
      kind = adapter_kind
      instance = case kind
      when "memoria_core", ""
        MemoriaServer::Adapters::MemoriaCore.new
      when "emotion_aware_memoria_core"
        MemoriaServer::Adapters::EmotionAwareMemoriaCore.new
      when "http"
        MemoriaServer::Adapters::Http.new
      else
        klass = Object.const_get(kind)
        instance = klass.new
        unless instance.is_a?(MemoriaServer::Adapter)
          raise ContractViolation, "MS_ADAPTER=#{kind} did not return a MemoriaServer::Adapter"
        end
        instance
      end
      instance.tap(&:boot)
    rescue NameError => e
      raise MemoriaServer::Error, "Unknown MS_ADAPTER=#{kind} (#{e.message})"
    end

    public

    def adapter=(instance)
      raise ContractViolation, "adapter must inherit MemoriaServer::Adapter" unless instance.is_a?(MemoriaServer::Adapter)
      @adapter = instance
    end

    # アダプタからの逆方向 push（utter/transfer/action）はトップレベルから呼べるようにする。
    # これらは `MemoriaServer::Push` への薄い委譲。
    def utter(...)
      Push.utter(...)
    end

    def transfer(...)
      Push.transfer(...)
    end

    def action(...)
      Push.action(...)
    end
  end
end

require_relative "memoria_server/redis_client"
require_relative "memoria_server/adapter"
require_relative "memoria_server/capability"
require_relative "memoria_server/capabilities/emotion"
require_relative "memoria_server/capabilities/motion"
require_relative "memoria_server/capabilities/expression"
require_relative "memoria_server/plugin"
require_relative "memoria_server/routines"
require_relative "memoria_server/plugins/schedule"
require_relative "memoria_server/streaming_metadata_extractor"
require_relative "memoria_server/context_builder"
require_relative "memoria_server/push"
require_relative "memoria_server/discord_relay"
require_relative "memoria_server/presence_manager"
require_relative "memoria_server/adapters/memoria_core"
require_relative "memoria_server/adapters/emotion_aware_memoria_core"
require_relative "memoria_server/adapters/http"
require_relative "memoria_server/audio"
