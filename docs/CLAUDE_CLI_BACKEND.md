# claude -p バックエンド

キャラクターの会話・思考ループと軽い作業を、Gemini API の代わりに `claude -p`（Claude Code のヘッドレス実行）で動かす選択肢です。既定は Gemini で、設定したときだけ使われます。

## 何が claude -p で動くか

| 処理 | 使うもの |
| --- | --- |
| 会話（`ChatSession#send_message`。Discord bot、`/api/chats`） | claude -p（`CLAUDE_CLI_MODEL`。込み入った会話では `CLAUDE_CLI_DEEP_MODEL`） |
| 思考ループと予定の実行（`Thinking::Thinker`） | claude -p（`CLAUDE_CLI_MODEL`） |
| ツールを使わない生成（`LlmClient#generate`）: 振り返り（SN）、タグ付け、睡眠フェーズ、ペット・読書伴走者の返答、読書の前処理 | claude -p（`CLAUDE_CLI_LIGHT_MODEL`） |
| Web検索 | Claude Code の WebSearch・WebFetch（会話と思考ループの両方で使える） |
| 埋め込み、音声の書き起こし | Gemini のまま（Claude に同じ機能がないため） |
| ストリーミングの会話（OpenAI互換API。デバイスからの会話） | Gemini のまま |

埋め込みなどは Gemini のままなので、`GEMINI_API_KEY` は引き続き必要です。

## 設定

```bash
MEMORIA_AGENT_BACKEND=claude_cli
CLAUDE_CLI_MODEL=sonnet         # 会話と思考ループ（既定: sonnet）
CLAUDE_CLI_DEEP_MODEL=opus      # 込み入った会話で切り替えるモデル（既定: opus）
CLAUDE_CLI_LIGHT_MODEL=haiku    # 振り返りやペットの返答などの軽い作業（既定: haiku）
# CLAUDE_CLI_COMMAND=claude     # claude コマンドのパス
# CLAUDE_CLI_TIMEOUT=600        # 1回の実行の上限（秒）
# CLAUDE_CLI_MAX_TURNS=20       # 1回の実行でのツール呼び出しの往復の上限
# CLAUDE_CLI_BUILTIN_TOOLS=WebSearch,WebFetch  # 会話と思考ループで使わせる Claude Code の組み込みツール
```

`claude` はインストール済みで、ログイン済み（または API キーを設定済み）である必要があります。memoria は認証情報を読みません。

## 仕組み

1. memoria はシステムプロンプト（`PromptBuilder` の出力）とプロンプトを渡して `claude -p` を起動します。会話のときは、これまでの会話を書き起こしてプロンプトに入れます
2. ツールは MCP サーバ `bin/memoria_mcp`（stdio）として渡します。Gemini のときと同じツール（記憶検索、予定、プラグインのツールなど）が同じ処理で実行されます
3. Claude Code の組み込みツールは、読むだけの WebSearch・WebFetch だけを使います。Bash・Edit などの書き換えや実行をするツール、設定ファイル、CLAUDE.md は使いません（`--tools`、`--setting-sources ""`、空の作業ディレクトリ）
4. MCP サーバは実行したツールを一時ファイルに記録し、memoria はそれを会話ログ（FL）に反映します。Web検索の呼び出しは claude の出力（stream-json）から拾います

軽い作業は、ツールなしで `claude -p` を1回呼びます。利用枠の中で動くので、API の利用額（`ApiUsageLog`）には記録しません。

### 強いモデルへの切り替え

会話では `use_deep_model` ツールが使えます。開発の相談や設計の壁打ちのような込み入った会話になったとキャラクターが判断すると、このツールを呼びます。その返答から `CLAUDE_CLI_DEEP_MODEL` で作り直し、会話が終わる（セッションが閉じる）まで強いモデルのまま続きます。

### 使えなかったとき

claude -p が失敗したとき（異常終了、タイムアウト、利用枠切れなど）、Gemini で代わりに動くことはしません。黙って止まらないように知らせます。

- 会話: 「⚠️ memoria: claude -p が使えなかったので、返答できませんでした（理由）」と返します（会話の履歴には残しません）
- 予定の実行: 予定の失敗として連絡手段（Discord など）に知らせます
- 予定によらない思考ループ: 同じ形の文を連絡手段に送ります。続けて失敗しても1時間に1回まで
- 軽い作業: 呼び出し元の処理が失敗します（振り返りなどは、Gemini の API が失敗したときと同じ扱い）

## 規約について

claude -p をサブスクリプション（Claude Pro / Max など）で使う場合は、Anthropic の規約に従ってください。要点:

- 自分のマシンで、自分のサブスクリプションで、自分のために使うこと。他の人にサブスクリプションの利用枠を使わせる形（共有のサーバとして公開するなど）は認められていません
- 他の人に使わせるなら API キー（`ANTHROPIC_API_KEY`）で使ってください

詳しくは [Claude Code の Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) を参照してください。規約の順守は利用者の責任です。
