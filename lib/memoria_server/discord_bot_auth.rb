require "active_support/security_utils"

module MemoriaServer
  # Discord の bot がサーバーの入口を呼ぶときの認証。純粋関数。
  # bot の鍵は、端末の鍵（DeviceKey）・管理キー（AdminKey）とは別の仕組みで、この入口だけを通す。
  # 逆に、端末の鍵と管理キーは、この入口を通らない（Api::V1::BaseController を継承しない）。
  #
  # 契約:
  # - authorized?: 期待する鍵が空（未設定）なら、常に false（鍵がないときに、誰でも通ることはない）
  # - authorized?: Authorization ヘッダの Bearer の値が期待する鍵と一致するときだけ true。比較は定数時間
  module DiscordBotAuth
    module_function

    def bearer(header)
      header.to_s[/\ABearer\s+(.+)\z/i, 1]
    end

    def authorized?(header, expected)
      return false if expected.to_s.strip.empty?

      provided = bearer(header)
      return false if provided.nil?

      ActiveSupport::SecurityUtils.secure_compare(provided, expected.to_s.strip)
    end
  end
end
