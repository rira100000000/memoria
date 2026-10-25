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

    # オプション：予定の時刻や思考ループで、キャラクターを起こす。ユーザーの発話なしに、
    # キャラクター自身が考えて動く。記憶の想起・プロンプト・LLM の呼び出し・記憶への保存はアダプタが持つ。
    # 実行しなかったときは MemoriaServer::WakeSkipped を raise する。それ以外の例外はやり直しの対象になる。
    #
    # @param wakeup [Hash, nil] 予定から起きたときの予定の内容。予定なしの思考ループでは nil
    #   { id: Integer（予定の ID）, purpose: String, action: String|nil ("share" なら必ず伝える予定), recurrence: String|nil,
    #     due_at: Time（予定の時刻）, remember: Boolean（起きて考えたことを記憶に残すか） }
    # @return [Hash] { share_message: String|nil（ユーザーに伝えたいこと）, summary: String|nil（やったことのまとめ）,
    #   recorded: Boolean（省略可。share_message をアダプタがもう会話の履歴に入れたなら true。memoria は record_outgoing を呼ばない） }
    def wake(character_id:, wakeup: nil)
      raise WakeSkipped, "このキャラクターのアダプタ（#{self.class.name}）は起床に対応していません"
    end

    # オプション：キャラクターの記憶から、query に関係するものを思い出す。
    # プラグインが、キャラクターの経験とつながった能力（読書で、読んだ一節から思い出すなど）を作るのに使う。
    # @return [String, nil] LLM のプロンプトにそのまま入れられる形の記憶。なければ nil
    def recall(character_id:, query:)
      nil
    end

    # オプション：text をキャラクターの記憶として残す。プラグインが、会話の外の体験（読み終えた本など）を記憶にするのに使う。
    # @param source [String] 体験の種類（"reading" など）。アダプタが振り返り方を選ぶのに使ってよい
    # @param metadata [Hash] 体験の情報（作品名など）
    # @return [Boolean] 記憶に残したか
    def memorize(character_id:, text:, source:, metadata: {})
      false
    end

    # オプション：wake の結果を memoria が連絡手段に送ったあとに呼ばれる。
    # 送った言葉を会話の履歴に入れ、ユーザーの返事がその続きになるようにする
    def record_outgoing(character_id:, text:)
      # noop by default
    end
  end
end
