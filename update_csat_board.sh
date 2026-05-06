#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Mexico CSAT Board Updater
# Queries Snowflake and regenerates data.js for the dashboard.
#
# Usage:  bash ~/DDRepos/mexico-csat-board/update_csat_board.sh
#
# Scoring:
#   CSAT (good) with customer comment  = 2 pts
#   CSAT (good) without comment        = 1 pt
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/data.js"
TMP=$(mktemp -d)

NORMA_EMAILS="'alejandro.nunezpriego@datadoghq.com','diego.corrales@datadoghq.com','patrizio.storms@datadoghq.com','emmanuel.prieto@datadoghq.com','emanuel.carmona@datadoghq.com','jonathan.maya@datadoghq.com'"
PABLO_EMAILS="'jaime.becerril@datadoghq.com','israel.lopez@datadoghq.com','alberto.bautista@datadoghq.com','marco.perez@datadoghq.com','fernanda.ramirez@datadoghq.com','cesar.medrano@datadoghq.com','eric.torres@datadoghq.com'"
ALL_EMAILS="${NORMA_EMAILS},${PABLO_EMAILS}"

echo "🇲🇽 Querying Snowflake for Mexico CSAT Board…"

# ── 1. Q2 aggregate — CSATs with / without comment per agent ──
snow sql --format json -q "
  SELECT
    u.EMAIL,
    SUM(CASE
          WHEN t.SATISFACTION_RATING_SCORE = 'good'
           AND t.SATISFACTION_RATING_COMMENT IS NOT NULL
           AND TRIM(t.SATISFACTION_RATING_COMMENT) != ''
          THEN 1 ELSE 0 END) AS CSAT_WITH_COMMENT,
    SUM(CASE
          WHEN t.SATISFACTION_RATING_SCORE = 'good'
           AND (t.SATISFACTION_RATING_COMMENT IS NULL OR TRIM(t.SATISFACTION_RATING_COMMENT) = '')
          THEN 1 ELSE 0 END) AS CSAT_NO_COMMENT,
    SUM(CASE WHEN t.SATISFACTION_RATING_SCORE = 'good' THEN 1 ELSE 0 END) AS TOTAL_GOOD_CSAT,
    SUM(CASE WHEN t.SATISFACTION_RATING_SCORE = 'bad'  THEN 1 ELSE 0 END) AS TOTAL_BAD_CSAT
  FROM REPORTING.GENERAL.DIM_ZENDESK_TICKET t
  JOIN REPORTING.GENERAL.DIM_ZENDESK_USER u ON t.ASSIGNEE_ID = u.ID
  WHERE t.SOLVED_TIMESTAMP >= '2026-05-01 00:00:00'
    AND t.SOLVED_TIMESTAMP <= CURRENT_TIMESTAMP
    AND u.EMAIL IN ($ALL_EMAILS)
  GROUP BY u.EMAIL
" > "$TMP/csat.json"
echo "  ✅ Aggregate data fetched"

# ── 2. May 2026 history — one row per CSAT ticket ─────────────
snow sql --format json -q "
  SELECT
    u.EMAIL,
    t.ID                          AS TICKET_ID,
    t.SATISFACTION_RATING_SCORE   AS SCORE,
    t.SATISFACTION_RATING_COMMENT AS COMMENT,
    TO_CHAR(t.SOLVED_TIMESTAMP, 'YYYY-MM-DD') AS SOLVED_DATE
  FROM REPORTING.GENERAL.DIM_ZENDESK_TICKET t
  JOIN REPORTING.GENERAL.DIM_ZENDESK_USER u ON t.ASSIGNEE_ID = u.ID
  WHERE t.SOLVED_TIMESTAMP >= '2026-05-01 00:00:00'
    AND t.SOLVED_TIMESTAMP <= CURRENT_TIMESTAMP
    AND t.SATISFACTION_RATING_SCORE = 'good'
    AND u.EMAIL IN ($ALL_EMAILS)
  ORDER BY t.SOLVED_TIMESTAMP DESC
" > "$TMP/history.json"
echo "  ✅ May history fetched"

# ── 3. Build data.js (inline Python) ──────────────────────────
python3 - "$TMP" "$OUT" << 'PYEOF'
import json, sys
from datetime import date, timedelta, datetime

tmp_dir, out_path = sys.argv[1], sys.argv[2]

NORMA_TEAM = [
    {"name": "Alejandro Nunez",   "email": "alejandro.nunezpriego@datadoghq.com", "initials": "AN", "color": "#9B59D0", "team": "norma"},
    {"name": "Diego Corrales",    "email": "diego.corrales@datadoghq.com",         "initials": "DC", "color": "#E07832", "team": "norma"},
    {"name": "Patrizio Storms",   "email": "patrizio.storms@datadoghq.com",        "initials": "PS", "color": "#5282E0", "team": "norma"},
    {"name": "Emmanuel Prieto",   "email": "emmanuel.prieto@datadoghq.com",        "initials": "EP", "color": "#52C87A", "team": "norma"},
    {"name": "Emanuel Baltazar",  "email": "emanuel.carmona@datadoghq.com",        "initials": "EB", "color": "#E0C452", "team": "norma"},
    {"name": "Jonathan Maya",     "email": "jonathan.maya@datadoghq.com",          "initials": "JM", "color": "#E05252", "team": "norma"},
]
PABLO_TEAM = [
    {"name": "Jaime Becerril",    "email": "jaime.becerril@datadoghq.com",         "initials": "JB", "color": "#58D9C8", "team": "pablo"},
    {"name": "Israel Lopez",      "email": "israel.lopez@datadoghq.com",           "initials": "IL", "color": "#D958A6", "team": "pablo"},
    {"name": "Alberto Bautista",  "email": "alberto.bautista@datadoghq.com",       "initials": "AB", "color": "#8ED952", "team": "pablo"},
    {"name": "Marco Perez",       "email": "marco.perez@datadoghq.com",            "initials": "MP", "color": "#52A6E0", "team": "pablo"},
    {"name": "Fernanda Ramirez",  "email": "fernanda.ramirez@datadoghq.com",       "initials": "FR", "color": "#E08052", "team": "pablo"},
    {"name": "Cesar Medrano",     "email": "cesar.medrano@datadoghq.com",          "initials": "CM", "color": "#A652E0", "team": "pablo"},
    {"name": "Eric Torres",       "email": "eric.torres@datadoghq.com",            "initials": "ET", "color": "#52E0A6", "team": "pablo"},
]
ALL_PLAYERS = NORMA_TEAM + PABLO_TEAM
EMAIL_TO_META = {p["email"].lower(): p for p in ALL_PLAYERS}

def load_list(fname):
    try:
        with open(f"{tmp_dir}/{fname}") as f:
            return json.load(f) or []
    except Exception as e:
        print(f"  ⚠️  Could not load {fname}: {e}", file=sys.stderr)
        return []

def load_by_email(fname):
    result = {}
    for row in load_list(fname):
        key = next((k for k in row if k.upper() == "EMAIL"), None)
        if key is None: continue
        result[row[key].lower()] = row
    return result

csat_rows   = load_by_email("csat.json")
history_raw = load_list("history.json")

# ── Players aggregate ──────────────────────────────────────────
players_out = []
for pm in ALL_PLAYERS:
    email = pm["email"].lower()
    cr = csat_rows.get(email, {})
    csat_with    = int(cr.get("CSAT_WITH_COMMENT", 0) or 0)
    csat_without = int(cr.get("CSAT_NO_COMMENT",   0) or 0)
    total_good   = int(cr.get("TOTAL_GOOD_CSAT",   0) or 0)
    total_bad    = int(cr.get("TOTAL_BAD_CSAT",    0) or 0)
    total_points = (csat_with * 2) + (csat_without * 1)
    players_out.append({
        **pm,
        "csatWithComment": csat_with,
        "csatNoComment":   csat_without,
        "totalGoodCsat":   total_good,
        "totalBadCsat":    total_bad,
        "totalPoints":     total_points,
    })

# ── May history ────────────────────────────────────────────────
csat_history = []
for row in history_raw:
    email_key = next((k for k in row if k.upper() == "EMAIL"), None)
    if not email_key: continue
    email = row[email_key].lower()
    meta  = EMAIL_TO_META.get(email)
    if not meta: continue

    comment    = (row.get("COMMENT") or "").strip()
    has_comment = bool(comment)
    points      = 2 if has_comment else 1

    # Format date nicely: 2026-05-06 → May 6
    raw_date = row.get("SOLVED_DATE") or ""
    try:
        d = datetime.strptime(raw_date, "%Y-%m-%d")
        nice_date = d.strftime("%b %-d")
    except Exception:
        nice_date = raw_date

    csat_history.append({
        "name":       meta["name"],
        "initials":   meta["initials"],
        "color":      meta["color"],
        "team":       meta["team"],
        "ticketId":   row.get("TICKET_ID"),
        "comment":    comment,
        "hasComment": has_comment,
        "points":     points,
        "date":       raw_date,
        "niceDate":   nice_date,
    })

# ── Team totals ────────────────────────────────────────────────
def team_total(team_id):
    return sum(p["totalPoints"] for p in players_out if p["team"] == team_id)

# ── Week label ─────────────────────────────────────────────────
today  = date.today()
monday = today - timedelta(days=today.weekday())
friday = monday + timedelta(days=4)
week_label = f"Week of {monday.strftime('%b %-d')} – {friday.strftime('%b %-d')}"

payload = {
    "generatedAt":  datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    "weekLabel":    week_label,
    "quarterStart": "2026-04-01",
    "teams": [
        {"id": "norma", "name": "Team Norma", "manager": "Norma Ruy Sanchez", "color": "#9B59D0", "totalPoints": team_total("norma")},
        {"id": "pablo", "name": "Team Pablo", "manager": "Pablo Acosta",       "color": "#E07832", "totalPoints": team_total("pablo")},
    ],
    "players":     players_out,
    "csatHistory": csat_history,
}

js = f"""// Auto-generated by update_csat_board.sh — do not edit manually
// Last updated: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}

const CSAT_DATA = {json.dumps(payload, indent=2)};
"""
with open(out_path, "w") as f:
    f.write(js)

norma_total = team_total("norma")
pablo_total = team_total("pablo")
top = max(players_out, key=lambda p: p["totalPoints"])
print(f"✅ data.js written — {len(csat_history)} May CSAT events")
print(f"   Team Norma: {norma_total} pts  |  Team Pablo: {pablo_total} pts")
print(f"   Top scorer: {top['name']} ({top['totalPoints']} pts)")
PYEOF

rm -rf "$TMP"

# ── Push to GitHub Pages ──────────────────────────────────────
cd "$SCRIPT_DIR"
if git -C "$SCRIPT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
  git -C "$SCRIPT_DIR" add data.js
  git -C "$SCRIPT_DIR" commit -m "chore: update CSAT data $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || echo "  (no changes to commit)"
  git -C "$SCRIPT_DIR" push origin main
  echo "🚀 Pushed to GitHub Pages"
else
  echo "  ℹ️  Not a git repo — skipping push."
fi

echo "🇲🇽 CSAT Board updated → $OUT"
