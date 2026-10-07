# プラグイン

キャラクターにツールと追加の指示を足す拡張。秘書や作業依頼のような個人的な用途を、memoria本体に手を入れずにリポジトリの外で実現するための入口。

memoriaの拡張の入口は3つある。

| 入口 | 差し替えるもの | 文書 |
|---|---|---|
| アダプタ | 記憶と応答生成（respond / memorize / reflect） | [ADAPTER_README.md](ADAPTER_README.md) |
| Capability | 出力の形式（emotion / motion など） | [ADAPTER_README.md](ADAPTER_README.md) の 3.5 |
| プラグイン | キャラクターが使えるツールと、追加の指示 | このファイル |

## 読み込み

環境変数 `MEMORIA_PLUGIN_PATHS` に、プラグインを置いたディレクトリを `:` 区切りで指定する。各ディレクトリ直下の `*.rb` が、Rails の初期化完了後に読み込まれる。

```
MEMORIA_PLUGIN_PATHS=/home/me/my-plugins
```

読み込みに失敗したファイルはログに残して飛ばす（キャラクター全体は止めない）。

## 書き方

`MemoriaServer::Plugin` を継承し、最後に `register` する。

```ruby
# /home/me/my-plugins/weather.rb
class WeatherPlugin < MemoriaServer::Plugin
  def name
    :weather
  end

  # このキャラクターで有効か（省略時は常に有効）
  def enabled_for?(character)
    character.name == "ハル"
  end

  # 場面ごとに出すツール。引数は JSON Schema（type は小文字）で書く
  def tools(scene:, platform: nil)
    return [] unless scene == :chat

    [{
      name: "get_weather",
      description: "指定した都市の今日の天気を調べる",
      parameters: {
        type: "object",
        properties: { city: { type: "string", description: "都市名" } },
        required: ["city"],
      },
    }]
  end

  # ツールの実行。Hash を返す（LLM にそのまま渡る）
  def execute(tool_name, args, character:, scene:)
    { weather: "晴れ", city: args["city"] }
  end

  # システムプロンプトの末尾に足す指示（省略可）
  def prompt_segment(character, scene:)
    "マスターに天気を聞かれたら get_weather で調べてから答える。"
  end
end

MemoriaServer::Plugin.register(WeatherPlugin.new)
```

### 場面（scene）

| scene | いつ | 注意 |
|---|---|---|
| `:chat` | マスターとの会話中 | マスターの依頼に応えて動く場面 |
| `:thinking` | 思考ループ | キャラが自分の意思で動く場面。費用や外部への影響が大きいツールは出さない |

`:chat` では `platform` に会話の経路が入る（Discord Bot からは `:discord`。それ以外の経路では `nil`）。

### 返り値の決まり

- `execute` は Hash を返す。エラーは `{ error: "..." }` で返すと、キャラクターが状況を理解して言葉にできる
- `execute` が例外を投げた場合も、memoria が `{ error: ... }` に変換してキャラクターに返す
- `:log` キーに文字列の配列を入れると、会話ログ（FL）に記録され、LLM には渡らない

### 長い作業の報告

時間のかかる作業はジョブとして裏で動かし、終わったら `wake` でキャラクターを起こす。キャラクターが自分の言葉でマスターに伝える。

```ruby
def execute(tool_name, args, character:, scene:)
  LongTaskJob.perform_later(character.id, args["task"])
  { accepted: true, note: "終わったら知らせる" }
end

# LongTaskJob の最後で
plugin = MemoriaServer::Plugin.find(:my_plugin)
plugin.wake(character, purpose: "頼まれていた作業の結果をマスターに伝える: #{summary}")
```

`wake` は「伝える（share）」予定として入るので、キャラクターが伝言を書かなかった場合や、失敗した場合も必ずマスターに届く。システムからのお知らせをそのまま送りたいときは `notify(character, text)` を使う。

## 組み込みのプラグイン

| name | 内容 |
|---|---|
| `schedule` | 予定の確認・追加・取り消し・承認。思考ループと、Discord での会話で使える。承認は会話でのみ |
| `pet_chat` | Discord での会話中にペットへ話しかける（思考ループ側のペットは Thinker が持つ） |
