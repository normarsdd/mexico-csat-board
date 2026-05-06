#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Mexico CSAT Board Updater
# Queries Snowflake and regenerates data.js for the dashboard.
#
# Usage:  bash /Users/norma.ruysanchez/Documents/mexico-csat/update_csat_board.sh
#
# Scoring:
#   CSAT (good) with customer comment  = 2 pts
#   CSAT (good) without comment        = 1 pt
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/data.js"
TMP=$(mktemp -d)

# ── Emails ────────────────────────────────────────────────────
# NOTE: verify Zendesk emails if any come back with 0 CSATs unexpectedly

NORMA_EMAILS="'alejandro.nunezpriego@datadoghq.com','diego.corrales@datadoghq.com','patrizio.storms@datadoghq.com','emmanuel.prieto@datadoghq.com','emanuel.carmona@datadoghq.com','jonathan.maya@datadoghq.com'"

PABLO_EMAILS="'jaime.becerril@datadoghq.com','israel.lopez@datadoghq.com','alberto.bautista@datadoghq.com','marco.perez@datadoghq.com','fernanda.ramirez@datadoghq.com','cesar.medrano@datadoghq.com','eric.torres@datadoghq.com'"

ALL_EMAILS="${NORMA_EMAILS},${PABLO_EMAILS}"

echo "🇲🇽 Querying Snowflake for Mexico CSAT Board…"

# ── 1. CSATs with and without customer comment ────────────────
# SATISFACTION_COMMENT is the customer-written comment on the CSAT rating.
# If the column doesn't exist in your schema, replace with the correct column name.
snow sql --format json -q "
  SELECT
    u.EMAIL,
    SUM(CASE
          WHEN t.SATISFACTION_RATING_SCORE = 'good'
           AND t.SATISFACTION_COMMENT IS NOT NULL
           AND TRIM(t.SATISFACTION_COMMENT) != ''
          THEN 1 ELSE 0
        END) AS CSAT_WITH_COMMENT,
    SUM(CASE
          WHEN t.SATISFACTION_RATING_SCORE = 'good'
           AND (t.SATISFACTION_COMMENT IS NULL OR TRIM(t.SATISFACTION_COMMENT) = '')
          THEN 1 ELSE 0
        END) AS CSAT_NO_COMMENT,
    SUM(CASE WHEN t.SATISFACTION_RATING_SCORE = 'good' THEN 1 ELSE 0 END) AS TOTAL_GOOD_CSAT,
    SUM(CASE WHEN t.SATISFACTION_RATING_SCORE = 'bad'  THEN 1 ELSE 0 END) AS TOTAL_BAD_CSAT
  FROM REPORTING.GENERAL.DIM_ZENDESK_TICKET t
  JOIN REPORTING.GENERAL.DIM_ZENDESK_USER u ON t.ASSIGNEE_ID = u.ID
  WHERE t.SOLVED_TIMESTAMP >= '2026-04-01 00:00:00'
    AND t.SOLVED_TIMESTAMP <= CURRENT_TIMESTAMP
    AND u.EMAIL IN ($ALL_EMAILS)
  GROUP BY u.EMAIL
" > "$TMP/csat.json"

echo "✅ CSAT data fetched"

# ── 2. Compute scores and write data.js (inline Python) ───────
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

def load_json(fname):
    try:
        with open(f"{tmp_dir}/{fname}") as f:
            raw = json.load(f)
        result = {}
        for row in (raw or []):
            key = next((k for k in row if k.upper() == "EMAIL"), None)
            if key is None:
                continue
            result[row[key].lower()] = row
        return result
    except Exception as e:
        print(f"  ⚠️  Could not load {fname}: {e}", file=sys.stderr)
        return {}

csat_rows = load_json("csat.json")

players_out = []
for pm in ALL_PLAYERS:
    email = pm["email"].lower()
    cr = csat_rows.get(email, {})

    csat_with    = int(cr.get("CSAT_WITH_COMMENT", 0) or 0)
    csat_without = int(cr.get("CSAT_NO_COMMENT",   0) or 0)
    total_good   = int(cr.get("TOTAL_GOOD_CSAT",   0) or 0)
    total_bad    = int(cr.get("TOTAL_BAD_CSAT",    0) or 0)

    # Scoring: with comment = 2pts, without comment = 1pt
    total_points = (csat_with * 2) + (csat_without * 1)

    players_out.append({
        **pm,
        "csatWithComment": csat_with,
        "csatNoComment":   csat_without,
        "totalGoodCsat":   total_good,
        "totalBadCsat":    total_bad,
        "totalPoints":     total_points,
    })

# Team totals
def team_total(team_id):
    return sum(p["totalPoints"] for p in players_out if p["team"] == team_id)

# Week label
today = date.today()
monday = today - timedelta(days=today.weekday())
friday = monday + timedelta(days=4)
week_label = f"Week of {monday.strftime('%b %-d')} – {friday.strftime('%b %-d')}"

# Build final payload
payload = {
    "generatedAt": datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    "weekLabel": week_label,
    "quarterStart": "2026-04-01",
    "teams": [
        {
            "id": "norma",
            "name": "Team Norma",
            "manager": "Norma Ruy Sanchez",
            "color": "#9B59D0",
            "totalPoints": team_total("norma"),
        },
        {
            "id": "pablo",
            "name": "Team Pablo",
            "manager": "Pablo Acosta",
            "color": "#E07832",
            "totalPoints": team_total("pablo"),
        },
    ],
    "players": players_out,
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
print(f"✅ data.js written")
print(f"   Team Norma: {norma_total} pts  |  Team Pablo: {pablo_total} pts")
print(f"   Top scorer: {top['name']} ({top['totalPoints']} pts)")
PYEOF

rm -rf "$TMP"

# ── Push to GitHub Pages ──────────────────────────────────────
REPO_DIR="$SCRIPT_DIR"
cd "$REPO_DIR"

if git -C "$REPO_DIR" rev-parse --git-dir > /dev/null 2>&1; then
  git -C "$REPO_DIR" add data.js
  git -C "$REPO_DIR" commit -m "chore: update CSAT data $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || echo "  (no changes to commit)"
  git -C "$REPO_DIR" push origin main
  echo "🚀 Pushed to GitHub Pages"
else
  echo "  ℹ️  Not a git repo — skipping push. Run from the cloned repo to auto-publish."
fi

echo "🇲🇽 CSAT Board updated → $OUT"
