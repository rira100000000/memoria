module MemoriaServer
  # アダプタ基底クラス。実装側はこれを継承し `respond` を実装する。
  #
  # contract:
  #   def respond(input, context:)
  #     # input   : String — ユーザーの最新発言（messages から抽出済み）
  #     # context : Hash   — ContextBuilder が組み立てた payload（character_id / device_id /
  #     #                    history / current_input / client_system_prompt / tools / tool_choice /
  #     #                    last_interaction_at / elapsed_since / client_metadata）
  #     #
  #     # 返り値: Enumerator または yield 可能なオブジェクト。各チャンクは Hash で
  #     #   { delta: "...", emotion: nil }       — 部分テキスト
  #     #   { tool_calls: [...] }                — ツール呼び出し
  #     #   { done: true, metadata: { ... } }    — 終端
  #     # を yield する。
  #   end
  #
  # 永続化要件：アダプタは `character_id` をキーに会話状態を永続化しなければならない。
  # 同じ character_id への以後のリクエストは過去文脈を踏まえて応答すること（クロスデバイス記憶継続）。
  class Adapter
    # アダプタ初期化時に1度呼ばれる（boot）。バックグラウンドジョブの登録など。
    # サブクラスでオーバーライド可能。
    def boot
      # noop by default
    end

    # 必須：ユーザー入力に対して応答チャンクを yield する Enumerator を返す。
    def respond(input, context:)
      raise NotImplementedError, "#{self.class.name}#respond must be implemented"
    end

    # オプション：会話コンテキストの境界が引かれたとき（ユーザー明示リセット等）に呼ばれる。
    # アダプタは短期文脈をクリアする等、独自の意味づけで処理する。
    # @param reason [String] "user_requested" / "elapsed_too_long" 等の理由ラベル
    def on_boundary(character_id:, reason:)
      # noop by default
    end

    # オプション：UI に過去履歴を表示するためのフェッチ。実装しない場合は空配列。
    # @return [Array<Hash>] [{ role:, content:, at: }, ...]
    def history(character_id:, limit: 50)
      []
    end
  end
end
