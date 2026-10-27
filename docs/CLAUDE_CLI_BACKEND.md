# claude -p バックエンド

キャラクターの会話・思考ループと軽い作業を、Gemini API の代わりに `claude -p`（Claude Code のヘッドレス実行）で動かす選択肢です。既定は Gemini で、設定したときだけ使われます。

## 何が claude -p で動くか

| 処理 | 使うもの |
| --- | --- |
| 会話（`ChatSession#send_message`。Discord bot、`/api/chats`） | claude -p（`CLAUDE_CLI_MODEL`。込み入った会話では `CLAUDE_CLI_DEEP_MODEL`） |
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
