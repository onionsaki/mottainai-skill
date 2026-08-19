#!/bin/sh
# analyze-usage.sh - the counting half of the "mottainai" skill (macOS / Linux).
#
# Reads Claude Code transcripts and prints a compact set of signals. Counting is
# mechanical, so it happens here, for free. Reading the signals is the agent's job.
#
# Uses only sh, find, sort and awk - all present on a stock macOS or Linux box,
# so there is nothing to install. No gawk-only functions are used: the date
# arithmetic below is plain integer math for exactly that reason.
#
# Privacy: conversation text is never read out. Only timestamps, token counts,
# model names, tool names and session titles are touched, and nothing leaves
# this machine.
#
# Usage:
#   ./analyze-usage.sh              # current 5-hour block + last 7 days
#   ./analyze-usage.sh -d 30        # widen the long window
#   ./analyze-usage.sh -l ja        # en | ja | ko

set -u

DAYS=7
LANGC=en
DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--days) DAYS="$2"; shift 2 ;;
    -l|--lang) LANGC="$2"; shift 2 ;;
    -p|--projects) DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REF="$SCRIPT_DIR/../reference"

if [ -z "$DIR" ]; then
  DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
fi

case "$LANGC" in ja) LCOL=3 ;; ko) LCOL=4 ;; *) LCOL=2 ;; esac

if [ ! -d "$DIR" ]; then
  echo "No transcripts found at: $DIR"
  exit 0
fi

FILES=$(find "$DIR" -name '*.jsonl' -type f -mtime -"$DAYS" -size +200c 2>/dev/null)
if [ -z "$FILES" ]; then
  echo "No transcripts found at: $DIR"
  exit 0
fi

NOW=$(date -u +%s)

# ---------------------------------------------------------------- extract
# One tab-separated record per event, prefixed with an epoch so the whole set
# can be ordered with sort(1) - awk has no portable sort of its own.
EXTRACT='
# awk turns a /regex/ constant into a boolean when it is passed as a function
# argument, so every pattern reused by pick()/num() is built as a string here.
BEGIN {
  Q = "\""
  P_TS  = Q "timestamp" Q ":" Q "[^" Q "]+" Q ;  X_TS  = Q "timestamp" Q ":" Q
  P_ID  = Q "id" Q ":" Q "msg_[^" Q "]+" Q ;     X_ID  = Q "id" Q ":" Q
  P_MOD = Q "model" Q ":" Q "[^" Q "]+" Q ;      X_MOD = Q "model" Q ":" Q
  P_IN  = Q "input_tokens" Q ":[0-9]+"
  P_WR  = Q "cache_creation_input_tokens" Q ":[0-9]+"
  P_RD  = Q "cache_read_input_tokens" Q ":[0-9]+"
  P_OUT = Q "output_tokens" Q ":[0-9]+"
  P_TH  = Q "thinking_tokens" Q ":[0-9]+"
}
function days_from_civil(y, m, d,   era, yoe, doy, doe) {
  if (m <= 2) y = y - 1
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function epoch_of(s,   y, mo, d, h, mi, se) {
  y  = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d  = substr(s, 9, 2) + 0
  h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se
}
# Slice by the literal prefix length. Stripping with a greedy /^.*:"/ would eat
# past colons inside the value itself, which timestamps are full of.
function pick(line, pat, prefix,   seg) {
  if (!match(line, pat)) return ""
  return substr(line, RSTART + length(prefix), RLENGTH - length(prefix) - 1)
}
function num(line, pat,   seg) {
  if (!match(line, pat)) return 0
  seg = substr(line, RSTART, RLENGTH)
  sub(/^[^0-9]*/, "", seg)
  return seg + 0
}
FNR == 1 {
  sid = FILENAME
  sub(/.*\//, "", sid); sub(/\.jsonl$/, "", sid)
  delete seen
  titled = 0
}
length($0) < 20 { next }
{
  if (!titled && match($0, /"(customTitle|aiTitle)":"[^"]+"/)) {
    t = substr($0, RSTART, RLENGTH)
    cp = index(t, ":\"")
    t = substr(t, cp + 2, length(t) - cp - 2)
    gsub(/\t/, " ", t)
    print "0\tT\t" sid "\t" t
    titled = 1
  }

  has_usage = index($0, "\"usage\":{") > 0
  is_result = (!has_usage) && index($0, "\"tool_result\"") > 0
  is_turn   = (!has_usage) && (!is_result) && index($0, "\"type\":\"user\"") > 0 \
              && index($0, "\"isMeta\":true") == 0
  is_fail   = is_result && index($0, "\"is_error\":true") > 0
  if (!has_usage && !is_turn && !is_fail) next

  ts = pick($0, P_TS, X_TS)
  if (ts == "") next
  ep = epoch_of(ts)
  # A session resumed today can carry weeks of older turns; window by the event
  # time, not just by the file being recently touched.
  if (ep < CUT) next

  if (is_turn || is_fail) {
    print ep "\tE\t" sid "\t" (is_turn ? 1 : 0) "\t0\t0\t0\t0\t0\tother\t" \
          (is_fail ? 1 : 0) "\t0\t0\t"
    next
  }

  # A streamed assistant message repeats across lines; count it once.
  id = pick($0, P_ID, X_ID)
  if (id != "") { if (id in seen) next; seen[id] = 1 }

  fam = "other"
  mv = pick($0, P_MOD, X_MOD)
  if (index(mv, "opus")) fam = "opus"
  else if (index(mv, "sonnet")) fam = "sonnet"
  else if (index(mv, "haiku")) fam = "haiku"
  else if (index(mv, "fable")) fam = "fable"

  tools = ""; rest = $0
  while (match(rest, /"type":"tool_use","id":"[^"]*","name":"[^"]+"/)) {
    seg = substr(rest, RSTART, RLENGTH)
    sub(/^.*"name":"/, "", seg); sub(/"$/, "", seg)
    tools = tools (tools == "" ? "" : ",") seg
    rest = substr(rest, RSTART + RLENGTH)
  }

  print ep "\tE\t" sid "\t0\t" \
        num($0, P_IN) "\t" \
        num($0, P_WR) "\t" \
        num($0, P_RD) "\t" \
        num($0, P_OUT) "\t" \
        num($0, P_TH) "\t" \
        fam "\t0\t" \
        (index($0, "\"isSidechain\":true") ? 1 : 0) "\t" \
        (index($0, "<scheduled-task name=") ? 1 : 0) "\t" tools
}
'

# ---------------------------------------------------------------- aggregate
AGG='
function pct(a, b) { return (b <= 0) ? 0 : int(100 * a / b + 0.5) }
function fmt(n) {
  if (n >= 1000000) return sprintf("%.1fM", n / 1000000)
  if (n >= 1000) return sprintf("%dk", int(n / 1000 + 0.5))
  return sprintf("%d", n)
}
function say(k, dflt) { return (k in LBL) ? LBL[k] : dflt }

BEGIN {
  FS = "\t"
  M_IN = 1.0; M_WR = 1.25; M_RD = 0.1
  PIN["opus"] = 5; POUT["opus"] = 25; PIN["sonnet"] = 3; POUT["sonnet"] = 15
  PIN["haiku"] = 1; POUT["haiku"] = 5; PIN["fable"] = 10; POUT["fable"] = 50
  PIN["other"] = 3; POUT["other"] = 15
  price_age = -1

  while ((getline ln < PRICES) > 0) {
    if (ln ~ /^#[ \t]*UPDATED:/) {
      d = ln; sub(/^.*UPDATED:[ \t]*/, "", d)
      price_age = int((NOW - (days_from_civil2(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 86400)) / 86400)
    } else if (ln !~ /^[ \t]*#/ && split(ln, pp, /[ \t]+/) >= 3) {
      PIN[pp[1]] = pp[2] + 0; POUT[pp[1]] = pp[3] + 0
    }
  }
  close(PRICES)

  while ((getline ln < LABELS) > 0) {
    if (ln ~ /^[ \t]*#/) continue
    n = split(ln, cc, "\t")
    if (n >= LCOL && cc[LCOL] != "") LBL[cc[1]] = cc[LCOL]
  }
  close(LABELS)
}
function days_from_civil2(y, m, d,   era, yoe, doy, doe) {
  if (m <= 2) y = y - 1
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

$2 == "T" { TITLE[$3] = $4; next }
$2 == "E" {
  n++
  EP[n] = $1; SID[n] = $3; TURN[n] = $4 + 0
  IN[n] = $5 + 0; WR[n] = $6 + 0; RD[n] = $7 + 0; OUT[n] = $8 + 0; TH[n] = $9 + 0
  FAM[n] = $10; ERR[n] = $11 + 0; SIDE[n] = $12 + 0; SCH[n] = $13 + 0; TL[n] = $14
}

function report(from, heading,   i, wRd, wFr, wOut, rRd, rFr, rOut, rTh, turns, errs,
                calls, wSide, wSch, wTot, rTot, p, wR, wF, wO, w, k, j, m, parts, best, bi, t) {
  print ""
  print "## " heading
  wRd = 0; wFr = 0; wOut = 0; rRd = 0; rFr = 0; rOut = 0; rTh = 0
  turns = 0; errs = 0; calls = 0; wSide = 0; wSch = 0
  split("", MW); split("", TW); split("", SW); split("", SR); split("", ST); split("", SF)

  for (i = 1; i <= n; i++) {
    if (EP[i] < from) continue
    s = SID[i]
    if (!(s in ST)) { ST[s] = 0; SW[s] = 0; SR[s] = 0; SF[s] = "" }
    if (TURN[i]) { turns++; ST[s]++; continue }
    errs += ERR[i]

    wR = RD[i] * M_RD * PIN[FAM[i]] / 1000000
    wF = (IN[i] * M_IN + WR[i] * M_WR) * PIN[FAM[i]] / 1000000
    wO = OUT[i] * POUT[FAM[i]] / 1000000
    w = wR + wF + wO

    wRd += wR; wFr += wF; wOut += wO
    rRd += RD[i]; rFr += IN[i] + WR[i]; rOut += OUT[i]; rTh += TH[i]
    if (SIDE[i]) wSide += w
    if (SCH[i]) wSch += w
    MW[FAM[i]] += w
    SW[s] += w; SR[s] += wR
    if (w > 0 && index(SF[s], FAM[i]) == 0) SF[s] = SF[s] (SF[s] == "" ? "" : "+") FAM[i]

    if (TL[i] != "") {
      m = split(TL[i], tt, ",")
      for (j = 1; j <= m; j++) if (tt[j] != "") { TW[tt[j]]++; calls++ }
    }
  }

  wTot = wRd + wFr + wOut
  rTot = rRd + rFr + rOut
  if (wTot <= 0) { print say("empty", "(no activity in this window)"); return }

  printf "weighted: %d%% %s / %d%% %s / %d%% %s\n", pct(wRd, wTot), say("reread", "re-reading"),
         pct(wFr, wTot), say("fresh", "new content"), pct(wOut, wTot), say("reply", "replies")
  printf "raw tokens: %s total (%s reread / %s new / %s out)\n", fmt(rTot), fmt(rRd), fmt(rFr), fmt(rOut)

  parts = ""
  for (j = 1; j <= 5; j++) {
    best = -1; bi = ""
    for (k in MW) if (!(k in MDONE) && MW[k] > best) { best = MW[k]; bi = k }
    if (bi == "") break
    MDONE[bi] = 1
    parts = parts (parts == "" ? "" : " / ") bi " " pct(MW[bi], wTot) "%"
  }
  split("", MDONE)
  print "models: " parts

  print ""
  print "### " say("sessions", "Heaviest sessions")
  for (j = 1; j <= 5; j++) {
    best = -1; bi = ""
    for (k in SW) if (!(k in DONE) && SW[k] > best) { best = SW[k]; bi = k }
    if (bi == "" || best <= 0) break
    DONE[bi] = 1
    t = (bi in TITLE) ? TITLE[bi] : "(untitled)"
    # Only clip pure-ASCII titles: outside a UTF-8 locale substr() cuts bytes,
    # which would slice a Japanese or Korean character in half.
    if (t ~ /^[ -~]*$/ && length(t) > 40) t = substr(t, 1, 40)
    printf "- %d%% | turns %d | reread %d%% | %s | %s\n", pct(SW[bi], wTot), ST[bi],
           pct(SR[bi], SW[bi]), SF[bi], t
  }
  split("", DONE)

  print ""
  print "### " say("signals", "Signals")
  ns = 0; for (k in ST) ns++
  printf "- %s: %d across %d sessions\n", say("turns", "user turns"), turns, ns
  printf "- tool calls: %d, %s: %d (%d%%)\n", calls, say("failed", "failed tool results"), errs, pct(errs, calls)
  printf "- %s: %d%%\n", say("thinking", "thinking share of replies"), pct(rTh, rOut)
  printf "- %s: %d%%   %s: %d%%\n", say("subagent", "subagent share"), pct(wSide, wTot),
         say("scheduled", "scheduled-task share"), pct(wSch, wTot)

  parts = ""
  for (j = 1; j <= 6; j++) {
    best = -1; bi = ""
    for (k in TW) if (!(k in TDONE) && TW[k] > best) { best = TW[k]; bi = k }
    if (bi == "" || best <= 0) break
    TDONE[bi] = 1
    parts = parts (parts == "" ? "" : ", ") bi "x" TW[bi]
  }
  split("", TDONE)
  if (parts != "") print "- " say("tools", "top tools") ": " parts

  parts = ""
  for (k in SW) if (ST[k] <= 15 && pct(SW[k], wTot) >= 15) {
    t = (k in TITLE) ? TITLE[k] : "(untitled)"
    parts = parts (parts == "" ? "" : "; ") t " (" ST[k] " turns, " pct(SW[k], wTot) "%)"
  }
  if (parts != "") print "- " say("fewturns", "few turns but heavy") ": " parts
}

END {
  if (n == 0) { print "(no activity)"; exit }

  # The real limit is a rolling window opened by the first prompt after a quiet
  # spell, so the block starts at the first event following a gap of 5h or more.
  blockStart = EP[1]
  for (i = 2; i <= n; i++) if (EP[i] - EP[i-1] >= 18000) blockStart = EP[i]

  print "# mottainai raw signals"
  print "weighted = cost-weighted share (read 0.1x, write 1.25x, reply 5x, per model price)."
  print "Claude Code transcripts only; claude.ai and the desktop app are not visible here."
  if (price_age >= 90) {
    st = say("stale", "PRICE TABLE IS {0} DAYS OLD - check https://www.anthropic.com/pricing")
    sub(/\{0\}/, price_age, st)
    print "! " st
  }

  hb = say("block", "CURRENT 5-HOUR BLOCK")
  report(blockStart, hb)
  hw = say("week", "LAST {0} DAYS")
  sub(/\{0\}/, DAYS, hw)
  report(0, hw)
}
'

CUT=$((NOW - DAYS * 86400))

echo "$FILES" | tr '\n' '\0' | xargs -0 awk -v CUT="$CUT" "$EXTRACT" 2>/dev/null \
  | sort -n \
  | awk -v LCOL="$LCOL" -v DAYS="$DAYS" -v NOW="$NOW" \
        -v PRICES="$REF/prices.tsv" -v LABELS="$REF/labels.tsv" "$AGG"
