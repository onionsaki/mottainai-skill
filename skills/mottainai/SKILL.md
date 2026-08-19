---
name: mottainai
description: Checks whether the user's Claude Code habits are costing them more of their usage allowance than they need to, and suggests what to change. Runs a bundled script that reads local transcripts, then reads the signals against ten known cost patterns. Read-only — it never changes settings or files. Use when the user asks "why do I hit the limit so fast", "check my token usage", "where are my tokens going", "am I using Claude Code efficiently", "what's eating my quota", or in Japanese 「もったいない使い方していない？」「節約できるところある？」「使用量をチェックして」「上限にすぐ達するのはなぜ」, or in Korean 「토큰 사용량 확인해줘」「사용량이 왜 이렇게 빨리 차나요」.
---

# mottainai — usage checkup

Finds what is eating the user's allowance and names the habit behind it.

**Read-only.** Report, then stop. Never edit settings, config, or transcripts.
**Report in the user's language**, whatever they wrote to you in.

## Why people open this

Usually because they just hit a limit, or watched `/usage` climb and got worried.
They are often not engineers. They want one thing they can do differently, not a
lecture. Give them that and get out of the way.

## Step 1 — run the counting script

Pick by platform. Both live next to this file and need nothing installed.

- **Windows**: `powershell -ExecutionPolicy Bypass -File "<skill-dir>/scripts/analyze-usage.ps1" -Lang en`
- **macOS / Linux**: `sh "<skill-dir>/scripts/analyze-usage.sh" -l en`

`-Lang` / `-l` accepts `en`, `ja`, `ko` only. For every other language, leave it
at `en` and translate the report yourself — that costs nothing extra.

Options: `-Days N` / `-d N` widens the long window (default 7).

**Do not read transcripts yourself with Read or Grep.** The script exists so the
counting is free. Hand-reading logs would cost more than this checkup can save.

If the script reports no transcripts, tell the user where it looked and mention
`CLAUDE_PROJECTS_DIR`. Do not go hunting.

## Step 2 — know what you are looking at

The script prints two windows: the **current 5-hour block** (which starts at the
first activity after a 5-hour-plus gap, matching how the real rolling limit
opens) and the **last 7 days**.

Each shows a **weighted** split and a **raw** token count. They differ, and the
weighted one is the honest one:

| | costs | why |
|---|---|---|
| re-reading the conversation | 0.1x | cached prefix, billed at a tenth |
| newly supplied content | 1.25x | writing to cache carries a premium |
| replies | 5x | output is the expensive end |

Raw token counts make re-reading look enormous — often 90% — because they treat
every token as equal. Weighted, it is usually a third to a half. **Lead with the
weighted number.** Mention raw only if the user asks.

Two limits to state plainly when they matter, and never paper over:

- **This is Claude Code only.** claude.ai and the desktop app draw on the same
  allowance and are invisible here.
- **It cannot show how much is left.** No local file holds that. This answers
  *what is costing you*, not *how much remains*. `/usage` answers the latter.

If the script prints a `!` line saying the price table is stale, then — and only
then — fetch https://www.anthropic.com/pricing once, compare against
`reference/prices.tsv`, and tell the user if a number moved. Otherwise never
touch the network.

## Step 3 — match the signals to a pattern

Ten patterns. Check each against the printed signals. Most runs match two or three.

| # | Pattern | Trigger | Next time |
|---|---|---|---|
| 1 | **Long haul** | a session is ≥20% of the window and its reread is ≥55% | Start a fresh conversation when the topic changes (`/clear`) |
| 2 | **Heavy load-in** | the `few turns but heavy` line is present | Hand over only the files needed; summarise big documents first |
| 3 | **Wrong model** | opus ≥40% and the heavy sessions' tools are mostly Edit/Write/Read/Bash | Drop to a mid model (`/model`) for work with a known answer |
| 4 | **Repeat grind** | one tool is ≥40% of all calls, or ≥30 calls | Do it once as a script, or use the source app's bulk action |
| 5 | **Drip feeding** | raw output ÷ user turns is under ~1,500 | Ask for several things in one message instead of one at a time |
| 6 | **Scheduled creep** | scheduled-task share ≥15% | Run it less often, or narrow what each run does |
| 7 | **Screen work** | browser/screenshot tools ≥15% of calls | Screenshots are heavy; ask for page text rather than pictures |
| 8 | **Spinning** | failed tool results ≥10% | Failures stay in the conversation and get re-read; start clean after a run of errors |
| 9 | **Overthinking** | thinking share of replies ≥50% | Say when a task is simple, or drop to a lighter model |
| 10 | **Too many deputies** | subagent share ≥25% | Each subagent re-reads the background from scratch; use them for genuinely separate work |

Judge, don't just threshold. A title is a guess about what a session was for —
say "this looks like X, is that right?" rather than asserting it.

## Step 4 — write the report

Keep it short. Shape:

```
<one line: the biggest weighted item, as a fraction, in plain words>

The one that would help most is <pattern, in plain language>.
<two or three lines: which sessions, and what to do differently next time>

Also worth knowing:
- <at most two more, one line each>

Want to start with <the one thing>?
```

Rules:

- **At most three suggestions.** Ten patterns is the range you can detect, not
  the number you report. If more than three matched, name the count and ask
  first: *"there are N more — listing them will use more tokens, shall I?"*
- **Every suggestion carries its "next time" line.** Naming a cause without
  naming the change is not useful to someone who is worried.
- **Percentages, not raw counts**, in prose — "about half" beats "46%".
- Identify sessions by **date and title**, never by ID or filename.
- Nothing matched? Say so and stop. Do not manufacture a finding.
- Close with the cost of the checkup itself: *"this checkup added about 5,000
  tokens — a small slice of one 5-hour block."* A tool about spending should not
  hide its own. (Measured: this file plus the script's output plus a short
  report. Run inside an already-long conversation it costs more, because the
  whole conversation is re-read — worth saying if pattern 1 came up.)

## Tone

The user is worried about money or about being cut off. Do not add to it.

- Never: "wasteful", "inefficient", "too much", "you should have".
- Never remark on how large their usage is. High usage is not a fault.
- Frame every finding as a change available now, not a mistake already made.

## Never

- Change any setting, config file, or transcript
- Read conversation content — the signals are enough
- Convert tokens to money; this is about an allowance, not a bill
- Suggest changing their plan
- Write files unless the user asks

If they do ask for a script to replace a repeated manual job, write it then —
tailored to their actual case. Ship no templates; every situation differs.
