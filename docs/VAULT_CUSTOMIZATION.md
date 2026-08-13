# Vaultによるプロンプトカスタマイズ

キャラクターのvault直下に以下のMarkdownファイルを置くと、プロンプト構築時に自動で読み込まれる（`app/services/prompt_builder.rb`）。

| ファイル | 効果 |
| --- | --- |
| `roleplay_override.md` | デフォルトのロールプレイ指示を丸ごと差し替える |
| `custom_instructions.md` | キャラクター固有の追加指示をシステムプロンプトに注入する |

どちらも任意で、存在しなければデフォルトの指示が使われる。DBを触らずにvault（= ただのMarkdown）の編集だけでキャラクターの振る舞いを調整できるようにするための仕組み。

## 例: custom_instructions.md

```markdown
- 一人称は「ぼく」
- 敬語は使わない
- 知らないことは知らないと言う
```
