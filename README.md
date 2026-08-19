# mottainai

**A read-only checkup for your Claude Code token usage.**
「もったいない」— an agent skill that finds where your tokens are going, and suggests what to change.

Counting is mechanical, so a bundled script does it locally and for free. Reading the numbers and noticing what matters is left to the agent. Nothing is sent anywhere, and nothing is modified.

---

## What it does / できること

Ask your agent 「もったいない使い方していない？」 or *"check my token usage"*, and it will:

1. Aggregate your local Claude Code transcripts (`~/.claude/projects/`) with the bundled script
2. Read the breakdown against a set of savings principles
3. Report **at most three** concrete suggestions, in your language, with the single most useful one first

Typical finding: most people discover that the large majority of their consumption is not new work at all — it is the conversation being re-read on every turn. That points at a specific, easy habit change rather than a vague "use it less".

## Install

```bash
npx skills add onionsaki/mottainai-skill --skill mottainai --global --yes
```

Or copy `skills/mottainai/` into `~/.claude/skills/`.

Requires Node.js 18+. No API keys, no network access, no dependencies.

## Run the script on its own

The skill runs this for you, but it works standalone:

```bash
node skills/mottainai/scripts/analyze-usage.js --days 14
node skills/mottainai/scripts/analyze-usage.js --all --lang en
```

| Flag | Meaning |
| --- | --- |
| `--days N` | Window in days (default 30) |
| `--all` | All transcripts |
| `--lang en` | English labels (default Japanese) |

If your transcripts live elsewhere, set `CLAUDE_PROJECTS_DIR`.

## Privacy

The script reads your transcript files to count tokens. It **never prints conversation bodies** — only session titles, turn counts, model names, tool names and token totals. Everything stays on your machine; the skill makes no network requests.

## What it deliberately does not do

- Change any setting or file — it reports, you decide
- Convert tokens to money (token counts are not a bill)
- Suggest changing your plan
- Read transcripts by hand (that would cost more than it saves)

---

## 日本語

Claude Codeの会話ログを集計して、**トークン消費のどこが大きいか**を見つけ、減らす手を提案する読み取り専用のスキルです。

「もったいない使い方していない？」「節約できるところある？」「使用量をチェックして」などと声をかけると動きます。

数える部分はスクリプトが行うので、その分の消費はありません。**設定やファイルは一切変更せず、提案までを行います。** 会話の本文は読み込まず、見出しと数字だけを扱います。外部への送信もありません。

導入は上の `npx skills add` か、`skills/mottainai/` を `~/.claude/skills/` にコピーしてください。Node.js 18以降が必要です。

## License

MIT
