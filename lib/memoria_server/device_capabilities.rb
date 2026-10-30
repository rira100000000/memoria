module MemoriaServer
  # 端末が自分の capabilities を登録するときの、検証と更新（純粋関数）。
  # いまは `expression`（その端末が出せる表情・エモートの ID）だけを受け付ける。
  #
  # 契約:
  # - register は、引数を書き換えず、新しい Hash を返す（capabilities）
  # - 受け付けるキーだけを更新する。ほかのキー（登録済みの別の capability）は、そのまま残す
  # - 受け付けないキーは捨てて、ignored に名前を返す
  # - expression が Hash でなければ、更新せず errors に理由を返す
  # - expression の ID のうち、標準にないものは落として、dropped に返す（端末が、登録が効いたか知れるように）
  # - 同じ入力には、同じ出力を返す。登録を繰り返しても結果は変わらない（冪等）
  module DeviceCapabilities
    Result = Struct.new(:capabilities, :errors, :ignored, :dropped, keyword_init: true)

    ACCEPTED = %w[expression].freeze

    module_function

    # @param existing [Hash, nil] いまの登録
    # @param incoming [Hash, nil] 端末が送ってきた登録
    # @return [Result]
    def register(existing, incoming)
      current = (existing || {}).to_h.transform_keys(&:to_s)
      incoming = incoming.is_a?(Hash) ? incoming.transform_keys(&:to_s) : {}
      errors = {}
      dropped = {}
      updated = current.dup

      if incoming.key?("expression")
        raw = incoming["expression"]
        normalized = Capabilities::Expression.normalize_registration(raw)
        if normalized
          updated["expression"] = { "faces" => normalized[:faces], "emotes" => normalized[:emotes] }
          dropped["expression"] = Capabilities::Expression.unknown_ids(raw)
        else
          errors["expression"] = "faces と emotes を持つオブジェクトにしてください"
        end
      end

      Result.new(capabilities: updated, errors: errors, ignored: (incoming.keys - ACCEPTED).sort, dropped: dropped)
    end
  end
end
