# claude -p バックエンド

キャラクターの会話・思考ループと軽い作業を、Gemini API の代わりに `claude -p`（Claude Code のヘッドレス実行）で動かす選択肢です。既定は Gemini で、設定したときだけ使われます。

## 何が claude -p で動くか

| 処理 | 使うもの |
| --- | --- |
| 会話（`ChatSession#send_message`。Discord bot、`/api/chats`） | claude -p（`CLAUDE_CLI_CHAT_MODEL`。未設定なら `CLAUDE_CLI_MODEL`。込み入った会話では `CLAUDE_CLI_DEEP_MODEL`） |
| 思考ループと予定の実行（`Thinking::Thinker`） | claude -p（`CLAUDE_CLI_MODEL`） |
| ツールを使わない生成（`LlmClient#generate`）: 振り返り（SN）、タグ付け、睡眠フェーズ | claude -p（`CLAUDE_CLI_LIGHT_MODEL`） |
| Web検索 | Claude Code の WebSearch・WebFetch（会話と思考ループの両方で使える） |
| 埋め込み、音声の書き起こし | Gemini のまま（Claude に同じ機能がないため） |
| ストリーミングの会話（OpenAI互換API。デバイスからの会話） | Gemini のまま |

埋め込みなどは Gemini のままなので、`GEMINI_API_KEY` は引き続き必要です。

`LLM_CLI_BACKEND=codex` にすると、`claude -p` の代わりに `codex exec`（Codex CLI）で同じ処理を動かせます（[codex exec で動かす](#codex-exec-で動かす)）。

## 設定

```bash
MEMORIA_AGENT_BACKEND=claude_cli
CLAUDE_CLI_MODEL=sonnet         # 会話と思考ループ（既定: sonnet）
# CLAUDE_CLI_CHAT_MODEL=haiku   # 会話だけ別のモデルにする（未設定なら CLAUDE_CLI_MODEL）
CLAUDE_CLI_DEEP_MODEL=opus      # 込み入った会話で切り替えるモデル（既定: opus）
CLAUDE_CLI_LIGHT_MODEL=haiku    # 振り返りなどの軽い作業（既定: haiku）
# CLAUDE_CLI_COMMAND=claude     # claude コマンドのパス
# CLAUDE_CLI_IDLE_TIMEOUT=600   # 出力がこれだけとぎれたら止める（秒）
# CLAUDE_CLI_TIMEOUT=7200       # 1回の実行の経過時間の上限（秒）。出力が続いていても、これを超えたら止める
# CLAUDE_CLI_MAX_TURNS=20       # 1回の実行でのツール呼び出しの往復の上限
# CLAUDE_CLI_BUILTIN_TOOLS=WebSearch,WebFetch  # 会話と思考ループで使わせる Claude Code の組み込みツール（default で全部）
# CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER="tote=WebSearch,WebFetch;helper="  # キャラごとに上書き（vault_dir_name=ツール。空なら使わせない）
# CLAUDE_CLI_WORKDIR=/path/to/dir   # 会話と思考ループの作業ディレクトリ（既定: 空の一時ディレクトリ）
# CLAUDE_CLI_SETTINGS=/path/to/settings.json  # claude に渡す設定ファイル（権限の allow / deny など）
```

`claude` はインストール済みで、ログイン済み（または API キーを設定済み）である必要があります。memoria は認証情報を読みません。

## 仕組み

1. memoria はシステムプロンプト（`PromptBuilder` の出力）とプロンプトを渡して `claude -p` を起動します。会話のときは、これまでの会話を書き起こしてプロンプトに入れます
2. ツールは MCP サーバ `bin/memoria_mcp`（stdio）として渡します。Gemini のときと同じツール（記憶検索、予定、プラグインのツールなど）が同じ処理で実行されます
3. Claude Code の組み込みツールは、既定では読むだけの WebSearch・WebFetch だけを使います。利用者の Claude Code の設定ファイル（`~/.claude` など）は読みません（`--setting-sources ""`）
4. MCP サーバは実行したツールを一時ファイルに記録し、memoria はそれを会話ログ（FL）に反映します。組み込みツール（Web検索、ファイルの編集、コマンドの実行など）の呼び出しは claude の出力（stream-json）から拾います

軽い作業は、ツールなしで `claude -p` を1回呼びます。利用枠の中で動くので、API の利用額（`ApiUsageLog`）には記録しません。

### Claude Code のツールを全部渡す

`CLAUDE_CLI_BUILTIN_TOOLS=default` にすると、キャラクターは Claude Code と同じツール（Read・Edit・Write・Bash など）を使えます。`CLAUDE_CLI_WORKDIR` で作業ディレクトリを、`CLAUDE_CLI_SETTINGS` の設定ファイルで権限（`permissions.defaultMode`、`allow`、`deny`）を決めます。

キャラクターは Discord の書き込み、Web の内容、思考ループをきっかけに動きます。コマンドの実行を許すときは、次を必ず行ってください。

- `DISCORD_ALLOWED_USER_IDS` で、Discord bot が応答する相手を自分だけに絞る
- 取り返しのつかない操作（履歴の書き換え、外部への送信など）を設定ファイルの `deny` で拒否する
- 作業ディレクトリの中身を、キャラクターが消せない場所（リモートなど）にも残しておく

### 止めるとき

claude -p の実行は、経過時間ではなく出力のとぎれで止めます。途中経過やツールの呼び出しが続いているあいだは動かし続け、出力が `CLAUDE_CLI_IDLE_TIMEOUT` 秒（既定: 600秒）とぎれたら、止まったものとして止めます。経過時間の上限 `CLAUDE_CLI_TIMEOUT`（既定: 7200秒）は、止まらなくなったときの安全弁として残しています。

長いベンチマークや学習のように、出力もツール呼び出しもないまま長く動く処理のために、キャラクターのツールに `long_think(minutes, reason)` を足しています。キャラクターがこれを呼ぶと、今から `minutes` 分（上限60分）は出力がなくても止めません。期限を過ぎると、ふだんの許容時間に戻ります。途中経過を受け取る会話（Discord など）では「長考中（〜N分：理由）」と知らせます。

宣言は、MCP サーバが実行ごとの一時ディレクトリのファイル（環境変数 `MEMORIA_MCP_LONG_THINK` で渡す）に書き、memoria がそれを読みます。並行して動く実行どうしで混ざることはありません。

### ツールの使用記録

MCP サーバは、ツールが呼ばれるたびに `data/tool_calls/usage.jsonl` へ1行ずつ記録します（`ClaudeCli::ToolUsageLog`）。残すのは時刻（日本時間）、ツール名、場面（`chat` / `thinking_loop` / `wakeup`）、trigger・platform、予定から起きたときは予定の ID と目的、成否、所要時間（ms）です。引数や結果の本文は残しません。書き込みに失敗してもツールは動き続け、ログに警告だけ出します。組み込みツール（Web検索など）は MCP を通らないので、ここには入りません。

```
{"date":"2026-10-25","at":"2026-10-25T10:46:16+09:00","tool":"list_schedules","scene":"wakeup","trigger":"thinking_loop","character_id":1,"wakeup_id":42,"purpose":"朝の見回り","ok":true,"ms":6}
```

集計は `bin/tool_usage` で出します（Rails を読み込まずに動きます）。

```bash
bin/tool_usage                                     # 全期間
bin/tool_usage --days 7                            # 今日を含む直近7日
bin/tool_usage --since 2026-10-20 --until 2026-10-26
bin/tool_usage --json                              # 集計を JSON で
```

### 強いモデルへの切り替え

会話では `use_deep_model` ツールが使えます。開発の相談や設計の壁打ちのような込み入った会話になったとキャラクターが判断すると、このツールを呼びます。その返答から `CLAUDE_CLI_DEEP_MODEL` で作り直し、会話が終わる（セッションが閉じる）まで強いモデルのまま続きます。

### 表情の指定（expression）

立ち絵のクライアントが、リクエストの `x_memoria.wants` に `expression` を入れると、キャラクターは返答といっしょに、立ち絵に出す表情（`face`）と演出（`emote`）を選びます。claude -p の構造化返答に `expression` の項目を足し、使い方の指示を system prompt に加えます。値はレスポンスの `x_memoria.expression` に載ります（`{ "face": "joy", "emote": "joy-clap" }`。演出なしは `"none"`）。

- 語彙は `lib/memoria_server/capabilities/expression.rb`。クライアントが持つ表情・エモートの ID と一致させる
- `wants` に入れたときだけ働く。Discord などには影響しない。Gemini のバックエンドでは働かない（値は返らない）
- 語彙にない `face` は返さず、語彙にない `emote` は `none` にする

#### 端末ごとの語彙（登録）

端末が出せる表情・エモートは、端末ごとに違う（Stack-chan のように、素材の数に限りがある端末もある）。標準の語彙（ID と意味）はサーバーが持ち、端末は、自分が出せる ID だけを登録する。リクエストのたびに送る必要はない。

```
PUT /api/v1/me/capabilities      端末の鍵。自分の端末の登録だけを変える
{ "capabilities": { "expression": { "faces": ["joy", "sadness"], "emotes": ["goodbye-wave"] } } }
GET /api/v1/me/capabilities      いまの登録
```

- 標準にない ID と重複は落とす（落とした ID は応答の `dropped` に返る）。faces には必ず `neutral` が入る。emotes は空でもよい（演出を使わない端末）。受け付けないキーは `ignored` に返る。形が違うときは 422
- 登録は `devices.capabilities`（JSON）に保存する。登録していない端末は、標準の語彙すべてを使える（既存のクライアントは変更なしで動く）
- キャラクターには、毎ターンの背景で、その端末が出せるものだけを伝える。返答の値も、その端末の語彙に絞る（出せない face は返さず、出せない emote は `none`）。同じ会話の claude を、端末が変わっても使い続ける
- 登録の検証と更新は `MemoriaServer::DeviceCapabilities`、語彙の判断は `Capabilities::Expression`（どちらも純粋関数）

### 会話のあいだ claude -p を起動したままにする（常駐）

既定では、返答のたびに claude -p を起動し直すため、1往復に約5秒かかる（起動と MCP サーバの接続に約2秒、残りが応答）。`CLAUDE_CLI_PERSISTENT=1` にすると、会話の場面（返答を構造化して返すもの）だけ、claude を `--input-format stream-json` で起動したままにして、1往復を1〜2秒にする。キャッシュも効く。思考ループ・軽い作業・Gemini は従来どおり。

```bash
CLAUDE_CLI_PERSISTENT=1                 # 常駐を有効にする（既定: 切）
# CLAUDE_CLI_PERSISTENT_IDLE=3600       # 使われなくなった claude を止めるまでの秒数
# CLAUDE_CLI_PERSISTENT_MAX=4           # 同時に持つ claude の数の上限
# CLAUDE_CLI_PERSISTENT_MAX_CONTEXT=120000  # claude が覚えている入力がこのトークン数を超えたら、使い回さず起動し直す
```

仕組み:

- 会話の記録（ChatSessionRecord）ごとに claude を1本持つ（`lib/persistent_claude/`。Rails の再読み込みの対象外）。キャラクターごと、会話ごとに別のプロセスなので、コンテキストは混ざらない。鍵は記録の id・モデル・起動時に固定される値の指紋（system prompt・返答の形・ツールの権限・設定ファイルの中身など）。変わったら別の claude で、会話の履歴から起動し直す。**経路（Discord かデバイスの API か）は鍵に入れない**（経路が変わっても同じ claude を使う。下の「経路が変わっても1本」）
- system prompt は起動時に1回しか渡せないので、毎回変わるもの（時刻・記憶・今日の会話の流れ・前向き記憶・予定）は、毎ターンの user メッセージの先頭に「システムが添えた背景」として添える。予定と前向き記憶は、前に添えたものから変わったときだけ（空になったときは「いまはない」と伝える）
- 最初のターン（と起動し直したとき）は会話の全文を渡し、以降は新しい分だけ渡す。claude が見た範囲は、返答を会話の記録に追記したあとに進める。履歴と合わなくなったら（別のプロセスが書き足した、記録が変わった、追記できなかった）、その claude は捨てて、履歴から起動し直す
- 次の場合も、その claude は捨てる: 失敗・途中で終わった、強いモデルへの切り替え、裏の作業（run_in_background）が残った、ターンの外で動いた、入力が大きくなりすぎた。同じキャラクターの、閉じた会話の claude も止める
- 無言が続いたものは止める。プロセスの終了時にすべて止める。親が突然落ちても、claude は標準入力が閉じて終わる
- 1本あたりのメモリは約230MB（MCP の分は別）。再起動後の最初の返答は、起動のぶん遅い（約4秒）

注意: `.env` に書くと、同じプロセスで動く会話はすべて常駐になる。常駐を持たせるプロセス（`memoria-server`）の環境だけに設定する。jobs と Discord の bot には効かせない（ユニットで `CLAUDE_CLI_PERSISTENT=0` を明示すると、`.env` に書かれても無効のまま）。

#### 経路が変わっても1本

1つの会話の記録に claude は1本で、Discord とデバイスの API を行き来しても使い続ける。起動時に固定されるものから経路を外し、毎ターンの背景と、ツールの呼び出し時に伝える。

- **経路（platform・channel）**: system prompt には入れず、毎ターンの背景に「あなたは現在、…を通じて会話しています」と添える（`ConversationRoute`）
- **返答の形**: 登録されたすべての capability の項目を「なくてもよい」形で持つ（`ReplySchema.for_process`）。付ける項目は、毎ターンの背景で指示する（欲しくないものは「付けない」と伝える）。返してよいのは、そのリクエストが欲しがった項目だけ
- **ツール**: すべての経路のツールの和集合で起動する（`ClaudeCli::ToolCatalog`）。呼ばれたとき、Runner が毎ターン書く経路のファイル（`MEMORIA_MCP_ROUTE`）を読み、いまの経路で使えるツールだけ実行する（`ToolProvider::RoutedChat`）

### サーバーを1本にする（memoria-server）

常駐した claude は、起動した Rails プロセスの中にしか存在しない。会話を作るプロセスを1本にして、そこだけが claude を持つ。

```
Discord の bot ─────────┐  POST /api/v1/discord/reply（bot 専用の鍵）
Windows クライアント ───┼─ HTTP（127.0.0.1）→ memoria-server（puma 1プロセス）→ 常駐の claude（会話の記録ごとに1本）
（門番 = 試作の専用サーバー）┘  POST /api/v1/chat/completions（端末の鍵）
```

- ユニット: `deploy/systemd/memoria-server.service`（`WEB_CONCURRENCY=0`・`RAILS_MAX_THREADS=16`・`MEMORIA_NO_RELOAD=1`・`BIND_HOST=127.0.0.1`・`PORT=3100`・`CLAUDE_CLI_PERSISTENT=1`）。コードの反映はサーバーの再起動で行う（再読み込みは切る。ストリーミング中の返答があると、再読み込みが全リクエストを止めるため）
- Discord の入口は bot 専用の鍵（`MEMORIA_BOT_TOKEN`、または `MEMORIA_BOT_TOKEN_FILE`）だけを通す。端末の鍵・管理キーは通さず、bot の鍵も他の入口では通らない。キャラクターは、bot からは受け取らず、チャンネル ID からサーバーが引く。経路は `discord` に固定し、送り手の許可（`DISCORD_ALLOWED_USER_IDS`）もサーバーで確かめる
- 返答は Server-Sent Events: `accepted`（順番待ちの前に1回）→ `message`（途中経過と最後の返答）→ `done`（または `error`）。15秒おきに ping。`done` がないまま切れたときは、bot が「途中で切れた」と返す（再送しない。返答は記録されている）。形式は `MemoriaServer::DiscordProtocol`
- bot は `MEMORIA_SERVER_URL` があればサーバーに頼む。なければ従来どおり、自分のプロセスの中で返答する（戻すときは、この変数を外す）
- 同じキャラクターの別の返答を待つ上限は、Discord の入口で `DISCORD_TURN_WAIT`（既定 300秒）。超えたら `error`（busy）
- 順番待ちのロックは、DB の隣（`storage/locks`。`MEMORIA_LOCK_DIR` で変えられる）に置く。作業ツリーが違っても、同じ DB を使うプロセスは同じロックを見る（`TurnLock`）
- jobs（Solid Queue）は、常駐を使わず、従来どおり自分のプロセスで動く。起こされて話すときも、同じ順番待ちを通り、会話の記録に追記する。サーバーの claude は、次のターンで、足された分を「別の場所であった会話」として受け取る
- Windows クライアントの試作（門番）は、`memoria-server` が動いていれば会話をそこへ転送し、動いていなければ自分のプロセスの中の Rails で返す（従来どおり）

MCP サーバの Rails の読み込みを最初のツール呼び出しまで遅らせる `CLAUDE_CLI_LAZY_MCP=1`（既定: 切）もある。体感の短縮は小さい（遅いのは Rails の読み込みではなく、claude が MCP を扱う時間）。

### 使えなかったとき

claude -p が失敗したとき（異常終了、タイムアウト、利用枠切れなど）、Gemini で代わりに動くことはしません。黙って止まらないように知らせます。

- 会話: 「⚠️ memoria: claude -p が使えなかったので、返答できませんでした（理由）」と返します（会話の履歴には残しません。codex のときは「codex exec が使えなかったので」）
- 予定の実行: 予定の失敗として連絡手段（Discord など）に知らせます
- 予定によらない思考ループ: 同じ形の文を連絡手段に送ります。続けて失敗しても1時間に1回まで
- 軽い作業: 呼び出し元の処理が失敗します（振り返りなどは、Gemini の API が失敗したときと同じ扱い）

## codex exec で動かす

`LLM_CLI_BACKEND=codex` にすると、会話・思考ループ・軽い作業のすべてを `codex exec` で動かします。未設定（または `claude`）なら従来どおり `claude -p` です。呼び出し側（会話・思考ループ・`LlmClient#generate`）は同じままで、`ClaudeCli::Runner` の後ろのバックエンド（`ClaudeCli::Backends::Claude` / `ClaudeCli::Backends::Codex`）だけが入れ替わります。

```bash
MEMORIA_AGENT_BACKEND=claude_cli
LLM_CLI_BACKEND=codex
CODEX_CLI_HOME=/path/to/codex-home-for-memoria   # memoria 専用の CODEX_HOME（下を参照）
# CODEX_CLI_COMMAND=codex                        # codex コマンドのパス（PATH にないとき。nvm などで入れたものはそのパス）
# CODEX_CLI_MODEL=gpt-6.1-sol:medium              # 会話と思考ループ（"モデル名:推論の強さ" でも書ける）
# CODEX_CLI_CHAT_MODEL=gpt-6-luna:medium          # 会話だけ別のモデルにする（未設定なら CODEX_CLI_MODEL）
# CODEX_CLI_DEEP_MODEL=gpt-6.1-sol:high           # 込み入った会話で切り替えるモデル
# CODEX_CLI_LIGHT_MODEL=gpt-6-luna:low            # 振り返りなどの軽い作業
# CODEX_CLI_SANDBOX=workspace-write               # CLAUDE_CLI_BUILTIN_TOOLS=default のときのサンドボックス
```

`CLAUDE_CLI_IDLE_TIMEOUT`・`CLAUDE_CLI_TIMEOUT`・`CLAUDE_CLI_WORKDIR`・`CLAUDE_CLI_BUILTIN_TOOLS`・`CLAUDE_CLI_BUILTIN_TOOLS_BY_CHARACTER` は codex でもそのまま使います。

`CODEX_CLI_COMMAND` をパスで指定したときは、そのディレクトリを `PATH` の前に足して起動します（npm で入れた codex は node のスクリプトなので、nvm などでは同じディレクトリの node が要ります）。

### 専用の CODEX_HOME

codex は `--ignore-user-config` を付けても、`$CODEX_HOME/AGENTS.md`（利用者の共通の指示）とスキルの一覧をプロンプトに入れます。キャラクターに利用者の指示が混ざらないように、memoria 専用の CODEX_HOME を用意して `CODEX_CLI_HOME` に指定してください。

```bash
CODEX_HOME=/path/to/codex-home-for-memoria codex login
```

ふだん使っている `~/.codex/auth.json` を複製して使うのは避けてください。トークンの更新が片方でしか反映されず、もう片方のログインが切れることがあります。

### claude -p との違い

codex-cli 0.164 で確かめた対応です。

| claude -p | codex exec |
| --- | --- |
| `--system-prompt` | ファイルに書いて `-c model_instructions_file=...` で渡す（Codex の既定の指示と置き換わる）。MCP のツールの呼び方を短く書き足す |
| `--output-format stream-json` | `--json`（JSON Lines。`item.started` / `item.completed` の `agent_message`・`mcp_tool_call`・`web_search`・`command_execution`・`file_change`、最後に `turn.completed` か `turn.failed`） |
| `--mcp-config`（ファイル） | `-c mcp_servers.memoria.*`。承認なしで呼べるように `default_tools_approval_mode="approve"`。MCP サーバには環境変数が引き継がれないので、名前を `env_vars` に並べる（値はコマンドラインに出さない） |
| `--json-schema` | `--output-schema`（ファイル）。OpenAI の strict な形が必要なので、すべての項目を `required` にし、省略できる項目は `null` を許す形に直す。返ってきた `null` の項目は除く |
| `--max-turns` | 相当するものがない。止めるのは出力のとぎれ（`CLAUDE_CLI_IDLE_TIMEOUT`）と経過時間の上限（`CLAUDE_CLI_TIMEOUT`）だけ |
| `--tools WebSearch,WebFetch` | `-c web_search="live"`。コマンドの実行などは `--disable shell_tool` などで止め、サンドボックスは `read-only` |
| `--tools default` と `--settings` | 機能は止めず、サンドボックスを `CODEX_CLI_SANDBOX`（既定: `workspace-write`）にする。`approval_policy="never"` |
| `--setting-sources ""` | `--ignore-user-config`、`project_doc_max_bytes=0`、`skills.include_instructions=false`。`$CODEX_HOME/AGENTS.md` は専用の CODEX_HOME で避ける |
| `--no-session-persistence` | `--ephemeral` |
| `--model sonnet` | `--model` と `-c model_reasoning_effort=...`（`CODEX_CLI_MODEL` などの `:` の後ろ） |

組み込みツールの記録の名前は、Web検索が `web_search`（Web のページを開いたものは `web_fetch`）、コマンドの実行が `shell`、ファイルの変更が `file_change` です。

## 規約について

claude -p をサブスクリプション（Claude Pro / Max など）で使う場合は、Anthropic の規約に従ってください。要点:

- 自分のマシンで、自分のサブスクリプションで、自分のために使うこと。他の人にサブスクリプションの利用枠を使わせる形（共有のサーバとして公開するなど）は認められていません
- 他の人に使わせるなら API キー（`ANTHROPIC_API_KEY`）で使ってください

詳しくは [Claude Code の Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) を参照してください。規約の順守は利用者の責任です。
