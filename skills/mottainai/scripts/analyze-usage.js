#!/usr/bin/env node
/**
 * analyze-usage.js
 *
 * Reads Claude Code transcripts (~/.claude/projects/ **\/*.jsonl) and prints a
 * breakdown of where tokens went. Counting is mechanical work, so it lives in a
 * script and costs no tokens. Interpreting the numbers is the agent's job.
 *
 * Claude Code の会話ログを読み、トークン消費の内訳を集計して出力する。
 * 数えるだけの機械作業をここに閉じ込めるのが目的。
 *
 *   node analyze-usage.js              # last 30 days / 直近30日
 *   node analyze-usage.js --days 7     # custom window / 期間を指定
 *   node analyze-usage.js --all        # everything / 全期間
 *   node analyze-usage.js --lang en    # English labels
 *
 * Privacy: conversation bodies are never read into the output. Only session
 * titles, counts and token totals are printed, and nothing leaves the machine.
 * 会話の本文は出力しない。見出しと数字だけを、この端末の中だけで扱う。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');

// ---------- args ----------
const argv = process.argv.slice(2);
const ALL = argv.includes('--all');
let DAYS = 30;
const di = argv.indexOf('--days');
if (di !== -1 && argv[di + 1]) DAYS = parseInt(argv[di + 1], 10) || 30;
const li = argv.indexOf('--lang');
const LANG = li !== -1 && argv[li + 1] === 'en' ? 'en' : 'ja';

// Transcript location. Override with CLAUDE_PROJECTS_DIR if your setup differs.
const PROJECTS_DIR =
  process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects');
const cutoff = ALL ? 0 : Date.now() - DAYS * 24 * 60 * 60 * 1000;

const T = {
  ja: {
    title: '# Claude Code 使用量サマリー',
    none: '会話ログが見つかりませんでした：',
    empty: '対象期間に集計できるセッションがありませんでした。',
    period: (p, n) => `対象: ${p}に動いていたセッション / ${n}件`,
    all: '全期間',
    days: (d) => `直近${d}日`,
    grand: (v) => `合計: ${v} トークン`,
    breakdown: '## 内訳（何にトークンが使われたか）',
    reread: '会話の読み直し（cache read）',
    fresh: '新しく渡した内容（input + cache create）',
    reply: 'Claudeの返答（output）',
    models: '## モデル別',
    top: '## 消費の大きいセッション（上位10件）',
    head: '| 開始日 | 発言数 | 合計 | 読み直しの割合 | モデル | タイトル |',
    sched: '## 定期実行タスク',
    schedNone: '- 対象期間に定期実行タスクのセッションはありませんでした',
    schedSome: (c, v, p) => `- ${c}セッション / ${v} トークン（全体の ${p}%）`,
    tools: '## よく使われたツール（上位8件）',
    times: '回',
    daily: '## 日別',
    untitled: '(無題)',
    auto: '(定期実行)',
  },
  en: {
    title: '# Claude Code usage summary',
    none: 'No transcripts found at: ',
    empty: 'No sessions to summarize in this window.',
    period: (p, n) => `Sessions active in ${p}: ${n}`,
    all: 'all time',
    days: (d) => `the last ${d} days`,
    grand: (v) => `Total: ${v} tokens`,
    breakdown: '## Where the tokens went',
    reread: 'Re-reading the conversation (cache read)',
    fresh: 'Newly supplied content (input + cache create)',
    reply: "Claude's replies (output)",
    models: '## By model',
    top: '## Heaviest sessions (top 10)',
    head: '| Started | Turns | Total | Re-read share | Model | Title |',
    sched: '## Scheduled tasks',
    schedNone: '- No scheduled-task sessions in this window',
    schedSome: (c, v, p) => `- ${c} sessions / ${v} tokens (${p}% of total)`,
    tools: '## Most used tools (top 8)',
    times: ' calls',
    daily: '## By day',
    untitled: '(untitled)',
    auto: '(scheduled)',
  },
}[LANG];

// ---------- helpers ----------
const fmt = (n) =>
  n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'k' : String(n);
const pct = (a, b) => (b === 0 ? 0 : Math.round((a / b) * 100));
const shortModel = (m) =>
  !m ? '?' : m.includes('opus') ? 'Opus' : m.includes('sonnet') ? 'Sonnet' : m.includes('haiku') ? 'Haiku' : m;

function listTranscripts(dir) {
  const out = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...listTranscripts(p));
    else if (e.name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

// ---------- read one session ----------
async function readSession(file) {
  const s = {
    title: null,
    firstTs: null,
    userTurns: 0,
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheCreate: 0,
    byModel: {},
    tools: {},
    scheduled: false,
  };
  const seen = new Set();

  const rl = readline.createInterface({
    input: fs.createReadStream(file, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });

  for await (const line of rl) {
    if (!line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }

    if (o.timestamp && !s.firstTs) s.firstTs = o.timestamp;
    if (!s.title && (o.customTitle || o.aiTitle)) s.title = o.customTitle || o.aiTitle;
    if (!s.scheduled && typeof o.content === 'string' && o.content.includes('<scheduled-task name=')) {
      s.scheduled = true;
    }

    const m = o.message;

    // Count only the human's own turns, not tool results.
    if (o.type === 'user' && m && !o.isMeta) {
      const c = m.content;
      const isToolResult = Array.isArray(c) && c.some((b) => b && b.type === 'tool_result');
      if (!isToolResult) s.userTurns++;
    }

    if (!m || !m.usage) continue;
    if (m.id) {
      if (seen.has(m.id)) continue; // streaming duplicates
      seen.add(m.id);
    }

    const u = m.usage;
    const inTok = u.input_tokens || 0;
    const outTok = u.output_tokens || 0;
    const cr = u.cache_read_input_tokens || 0;
    const cc = u.cache_creation_input_tokens || 0;
    s.input += inTok;
    s.output += outTok;
    s.cacheRead += cr;
    s.cacheCreate += cc;

    const model = shortModel(m.model);
    if (model !== '?' && !model.startsWith('<')) {
      s.byModel[model] = (s.byModel[model] || 0) + inTok + outTok + cr + cc;
    }

    if (Array.isArray(m.content)) {
      for (const b of m.content) {
        if (b && b.type === 'tool_use' && b.name) s.tools[b.name] = (s.tools[b.name] || 0) + 1;
      }
    }
  }

  s.total = s.input + s.output + s.cacheRead + s.cacheCreate;
  return s;
}

// ---------- main ----------
(async () => {
  const files = listTranscripts(PROJECTS_DIR);
  if (files.length === 0) {
    console.log(T.none + PROJECTS_DIR);
    process.exit(0);
  }

  const sessions = [];
  for (const f of files) {
    let st;
    try {
      st = fs.statSync(f);
    } catch {
      continue;
    }
    if (st.mtimeMs < cutoff) continue;
    if (st.size < 200) continue;
    try {
      const s = await readSession(f);
      if (s.total > 0) sessions.push(s);
    } catch {
      /* skip unreadable transcripts */
    }
  }

  if (sessions.length === 0) {
    console.log(T.empty);
    process.exit(0);
  }

  sessions.sort((a, b) => b.total - a.total);

  const grand = sessions.reduce((n, s) => n + s.total, 0);
  const totalCacheRead = sessions.reduce((n, s) => n + s.cacheRead, 0);
  const totalOutput = sessions.reduce((n, s) => n + s.output, 0);
  const totalFresh = sessions.reduce((n, s) => n + s.input + s.cacheCreate, 0);

  const modelTotals = {};
  for (const s of sessions)
    for (const [m, v] of Object.entries(s.byModel)) modelTotals[m] = (modelTotals[m] || 0) + v;

  const toolTotals = {};
  for (const s of sessions)
    for (const [t, c] of Object.entries(s.tools)) toolTotals[t] = (toolTotals[t] || 0) + c;

  const sched = sessions.filter((s) => s.scheduled);
  const schedTotal = sched.reduce((n, s) => n + s.total, 0);

  const days = {};
  for (const s of sessions) {
    const d = (s.firstTs || '').slice(0, 10);
    if (d) days[d] = (days[d] || 0) + s.total;
  }

  const L = [];
  L.push(T.title, '');
  L.push(T.period(ALL ? T.all : T.days(DAYS), sessions.length));
  L.push(T.grand(fmt(grand)), '');

  L.push(T.breakdown);
  L.push(`- ${T.reread}: ${fmt(totalCacheRead)}  ${pct(totalCacheRead, grand)}%`);
  L.push(`- ${T.fresh}: ${fmt(totalFresh)}  ${pct(totalFresh, grand)}%`);
  L.push(`- ${T.reply}: ${fmt(totalOutput)}  ${pct(totalOutput, grand)}%`, '');

  L.push(T.models);
  for (const [m, v] of Object.entries(modelTotals).sort((a, b) => b[1] - a[1]))
    L.push(`- ${m}: ${fmt(v)}  ${pct(v, grand)}%`);
  L.push('');

  L.push(T.top);
  L.push(T.head);
  L.push('| --- | --- | --- | --- | --- | --- |');
  for (const s of sessions.slice(0, 10)) {
    const models = Object.entries(s.byModel)
      .sort((a, b) => b[1] - a[1])
      .map(([m]) => m)
      .join('+');
    const title = (s.title || (s.scheduled ? T.auto : T.untitled)).slice(0, 30);
    L.push(
      `| ${(s.firstTs || '').slice(0, 10)} | ${s.userTurns} | ${fmt(s.total)} | ${pct(s.cacheRead, s.total)}% | ${models || '-'} | ${title} |`
    );
  }
  L.push('');

  L.push(T.sched);
  L.push(sched.length === 0 ? T.schedNone : T.schedSome(sched.length, fmt(schedTotal), pct(schedTotal, grand)));
  L.push('');

  L.push(T.tools);
  for (const [t, c] of Object.entries(toolTotals).sort((a, b) => b[1] - a[1]).slice(0, 8))
    L.push(`- ${t}: ${c}${T.times}`);
  L.push('');

  L.push(T.daily);
  for (const [d, v] of Object.entries(days).sort()) L.push(`- ${d}: ${fmt(v)}`);

  console.log(L.join('\n'));
})();
