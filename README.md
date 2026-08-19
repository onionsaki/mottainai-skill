# mottainai

**A read-only checkup for your Claude Code usage.**
Finds what is actually eating your allowance, and names the habit behind it.

「もったいない」 — *mottainai* — is the Japanese word for the pang you feel when
something useful goes to waste. That is the whole idea: not "use Claude less",
but "stop paying for the same thing twice".

---

## Why it exists

Most advice about token usage is either vague ("keep conversations short") or
wrong. It is wrong for a specific, checkable reason: people count raw tokens,
and raw tokens lie.

Re-reading a cached conversation is billed at **a tenth** of fresh input. Replies
cost **five times** it. Count every token as equal and re-reading looks like 90%
of everything you do — a scary number that points you at the wrong problem.
Weight them properly and it is usually a third to a half, sitting alongside two
other things worth knowing about.

`mottainai` does the weighting, then tells you which of ten known habits your
own logs actually show.

## What you get

Ask your agent 「もったいない使い方していない？」, *"why do I hit the limit so fast"*,
or *"check my token usage"*. It will:

1. Run the bundled script over your local transcripts — free, and offline
2. Split your **current 5-hour block** and your **last 7 days** by weighted cost
3. Match the signals against ten cost patterns
4. Report **at most three** things, most useful first, each with a "next time" line

It reports and stops. It never changes a setting, and it says what the checkup
itself cost.

### The ten patterns

Long haul · Heavy load-in · Wrong model · Repeat grind · Drip feeding ·
Scheduled creep · Screen work · Spinning · Overthinking · Too many deputies

Each has a mechanical trigger drawn from your logs, so two runs on the same data
agree with each other.

## Install

```bash
npx skills add onionsaki/mottainai-skill --skill mottainai --global --yes
```

Or copy `skills/mottainai/` into `~/.claude/skills/`.

**No installation required to run it.** Windows uses PowerShell, macOS and Linux
use `sh` + `awk` — all present on a stock machine. There is no Node.js
requirement, deliberately: the recommended Claude Code installer has not needed
Node since 2026, so a great many users do not have it.

## Running the script by itself

```bash
sh skills/mottainai/scripts/analyze-usage.sh -l en -d 7
```
```powershell
powershell -File skills\mottainai\scripts\analyze-usage.ps1 -Lang en -Days 7
```

| Flag | Meaning |
| --- | --- |
| `-l` / `-Lang` | `en`, `ja`, `ko`. Any other language is handled by the agent translating the report. |
| `-d` / `-Days` | Length of the long window (default 7) |
| `-p` / `-ProjectsDir` | Where transcripts live, if not `~/.claude/projects` (or set `CLAUDE_PROJECTS_DIR`) |

## What it cannot tell you

- **How much allowance is left.** Nothing on disk records that. `/usage` is the
  place for that question; this answers *what is costing you*.
- **Usage outside Claude Code.** claude.ai and the desktop app share the same
  limit and leave no trace here.

Both limits are stated in the report rather than glossed over.

## Privacy

The script reads transcript files to count tokens. It **never prints
conversation content** — only timestamps, token counts, model names, tool names
and the session titles Claude already generated. No network calls, ever, with a
single exception: when the bundled price table is more than 90 days old, the
agent checks the public pricing page once and offers to update it.

## Keeping prices current

`reference/prices.tsv` carries a dated price table. Structural multipliers
(0.1x / 1.25x / 5x) live in the scripts because they follow from how caching is
billed and rarely move; per-model prices live in the table because they do.
The scripts flag the table once it passes 90 days, so a stale table announces
itself instead of quietly skewing every report.

---

## 日本語

Claude Codeの使用量のうち、**何が枠を食っているか**を見つけて、その原因になっている
使い方に名前を付けて教えてくれる、読み取り専用のスキルです。

「もったいない使い方していない？」「節約できるところある？」などと声をかけると動きます。

**生のトークン数ではなく、重み付けした値で判断します。** 会話の読み直しは基準の0.1倍、
返答は5倍というように、種類ごとに費用が違うためです。全部を1倍で数えると「9割が読み直し」
という実態より大きな数字になり、対策を誤ります。

報告は多くても3つまで。それぞれに「次はこうする」の一文が付きます。設定は一切変更しません。

残量は分かりません（記録が残っていないため）。またスマホやブラウザのClaude分は含まれません。
どちらも報告の中で明記します。

Node.jsは不要です。Windowsは PowerShell、Mac/Linuxは シェル で動きます。

## License

MIT
