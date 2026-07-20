#!/usr/bin/env bash
# ============================================================================
#  🏦 IronBank — onboarding (fully cloud-hosted; nothing runs on your machine)
#
#      Telegram bot ──▶ Google Apps Script ──▶ Notion (record + dashboard)
#                                          └─▶ Splitwise (settlement)
#
#  What this script DOES (automated):
#    1. Collects + live-validates all four credentials
#       (Telegram bot token, Gemini key, Splitwise PAT, Notion token+page)
#       and pins your Telegram chat id (required — prevents bot hijack).
#    2. Provisions the 4 Notion databases (Expenses / People / Groups /
#       Splitwise Users) IDEMPOTENTLY — including the Month/Year formulas,
#       all relations, and the seeded Expense Type / Payment Mode options
#       that drive the parser. Re-runs prefer the database ids saved in the
#       state file (survives renames), then fall back to title matching.
#    3. After you deploy the Apps Script Web App, pushes all NON-SECRET
#       config into Script Properties through the Web App's updateConfig
#       action, and registers the Telegram webhook.
#    4. LIVE-VERIFIES every secret you pasted (diagnose — pass/fail only,
#       values never leave Apps Script), INSTALLS the 15-min sync trigger
#       through the Web App, and RUNS THE FIRST SYNC so your Splitwise
#       groups and contacts are already in Notion when you open it.
#
#  What it CANNOT automate (guided manual steps — no API exists for them):
#    A. Creating the Apps Script project (script.new) + pasting the loader
#       (this script copies the loader to your clipboard when it can).
#    B. Setting the four SECRETS in Script Properties (Google offers no
#       public API for Script Properties — and that's where secrets belong).
#    C. Deploying the Web App (interactive Google authorization).
#    D. Sharing the Notion parent page with your integration.
#    E. Building the Notion VIEWS — the Notion API cannot create views.
#       Follow dashboard_build_guide.html (or DASHBOARD.md) once at the end.
#
#  There is NO Google Sheet in IronBank: all config lives in Script
#  Properties, logs live in the Apps Script execution log.
#
#  Requirements: bash, curl, python3.
#  Windows: run this inside Git Bash (ships with Git for Windows) or WSL —
#  see "Running on Windows" in README.md. There is no separate .ps1/.bat
#  version; this script IS the Windows onboarding, via Git Bash.
#  Safe to re-run at any point; never prints secrets unless you ask.
# ============================================================================
set -euo pipefail

STATE_FILE=".ironbank_onboarding_state.json"   # non-secret state (db ids etc.)
SCHEMA_VERSION="1"                              # stamped into config for future schema migrations

# ── tiny helpers ────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
pause() { printf '\n'; read -r -p "  ↩  Press Enter when done... " _; }

# Find a Python that actually runs. On Windows, `python` can resolve to the Microsoft Store
# stub (which opens a browser and exits non-zero) — so test-run each candidate instead of
# trusting `command -v` alone.
PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
[ -n "$PY" ] || die "python3 is required (used for the Notion provisioning step). On Windows: install it from python.org and tick 'Add python.exe to PATH'."
command -v curl >/dev/null || die "curl is required."

# Prompt that prefers an already-exported env var (lets you script/re-run this).
ask() { # ask VAR "label" [secret]
  local var="$1" label="$2" secret="${3:-}" cur val
  cur="$(eval "printf '%s' \"\${$var:-}\"")"
  if [ -n "$cur" ]; then ok "$label — using value from \$$var"; return; fi
  if [ "$secret" = "secret" ]; then read -r -s -p "  $label: " val; printf '\n'
  else read -r -p "  $label: " val; fi
  [ -n "$val" ] || die "$label is required."
  eval "$var=\$val"
}

# ============================================================================
bold "IronBank onboarding — Telegram → Apps Script → Notion + Splitwise"
echo  "  Everything runs in Google/Notion/Splitwise clouds. No local server, no Google Sheet."
echo  "  NOTE: IronBank is INR-only today (non-INR Splitwise groups/expenses are excluded by design)."
echo

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 1/6 — Credentials (each is validated live before we continue)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  • Telegram bot token  → create a bot with @BotFather, copy the token"
echo "  • Gemini API key      → https://aistudio.google.com/apikey"
echo "  • Splitwise PAT       → https://secure.splitwise.com/apps → Register app → Personal Access Token"
echo "  • Notion token        → https://www.notion.so/my-integrations → New integration (internal)"
echo "  • Notion parent page  → recommended: duplicate the IronBank template into your workspace"
echo "                          (https://app.notion.com/p/IronBank-Template-3a3f0556bd7e80bfb29fd0c67e04168a),"
echo "                          then use YOUR copy's page. Or share any blank page — the script"
echo "                          creates the databases from scratch either way. SHARE the page with"
echo "                          the integration first: page ••• menu → Connections → your integration"
echo

ask TELEGRAM_BOT_TOKEN "Telegram bot token" secret
TG_ME=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe") \
  || die "Telegram rejected that bot token (getMe failed)."
BOT_USER=$("$PY" -c 'import sys,json;print(json.load(sys.stdin)["result"]["username"])' <<<"$TG_ME")
ok "Telegram bot verified: @${BOT_USER}"

ask GEMINI_API_KEY "Gemini API key" secret
curl -sf "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}" >/dev/null \
  || die "Gemini rejected that API key."
ok "Gemini key verified"

ask SPLITWISE_TOKEN "Splitwise Personal Access Token" secret
SW_ME=$(curl -sf -H "Authorization: Bearer ${SPLITWISE_TOKEN}" \
  "https://secure.splitwise.com/api/v3.0/get_current_user") \
  || die "Splitwise rejected that token (get_current_user failed)."
SW_FIRST=$("$PY" -c 'import sys,json;print(json.load(sys.stdin)["user"].get("first_name") or "")' <<<"$SW_ME")
SW_ID=$("$PY"    -c 'import sys,json;print(json.load(sys.stdin)["user"]["id"])' <<<"$SW_ME")
ok "Splitwise verified: ${SW_FIRST} (user id ${SW_ID})"

ask NOTION_TOKEN "Notion integration token" secret
ask NOTION_PARENT_PAGE_ID "Notion parent page id (from the page URL, dashes optional)"
# normalize a bare 32-hex id into dashed UUID form
NOTION_PARENT_PAGE_ID=$("$PY" -c '
import sys,re
s=re.sub(r"[^0-9a-fA-F]","",sys.argv[1])[-32:]
print(f"{s[0:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:32]}" if len(s)==32 else sys.argv[1])' "$NOTION_PARENT_PAGE_ID")
curl -sf -H "Authorization: Bearer ${NOTION_TOKEN}" -H "Notion-Version: 2022-06-28" \
  "https://api.notion.com/v1/pages/${NOTION_PARENT_PAGE_ID}" >/dev/null \
  || die "Notion can't read that page — wrong id, or the page isn't shared with the integration (manual step D)."
ok "Notion token + parent page verified"

# Owner name: what 'me/I/my' resolve to. Default = Splitwise first name so the
# bot's identity and Splitwise's agree out of the box.
read -r -p "  Your name as the bot should know you [${SW_FIRST:-Owner}]: " OWNER_NAME
OWNER_NAME="${OWNER_NAME:-${SW_FIRST:-Owner}}"
ok "Owner name: ${OWNER_NAME}"

# REQUIRED: pin your Telegram chat id. Without a pin, the FIRST chat that messages the
# bot auto-registers as the owner — anyone who finds your bot's username before you
# message it would own your instance. 30 seconds to fetch, permanent protection.
echo
echo "  Pin your Telegram chat id (required — prevents anyone else claiming your bot)."
echo "  Get your numeric id by messaging @userinfobot on Telegram."
if [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  ok "Telegram chat id — using value from \$TELEGRAM_CHAT_ID"
else
  while :; do
    read -r -p "  Your Telegram chat id (numeric): " TELEGRAM_CHAT_ID
    case "$TELEGRAM_CHAT_ID" in
      ''|-|*[!0-9-]*) warn "That doesn't look like a numeric chat id (e.g. 123456789) — try again." ;;
      *) break ;;
    esac
  done
fi
ok "Chat id pinned: ${TELEGRAM_CHAT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 2/6 — Link the 4 Notion databases (idempotent)"
# ─────────────────────────────────────────────────────────────────────────────
# If Groups / Splitwise Users / People / Expenses already exist under the parent
# page (e.g. you duplicated the template), they're found by exact title and their
# ids are pulled directly — nothing is created or duplicated. Only missing
# databases get created from scratch (Groups → Splitwise Users → People →
# Expenses order matters: relations need the target database id to exist).
# Re-run behaviour: prefers the database ids saved in the state file (survives
# renames), then finds existing child databases by exact title, and PATCHes
# in any missing properties — this also self-heals a template whose schema
# drifted from an older version. Select options are seeded only when the
# property itself is created — after that the live dropdowns are YOURS: adding
# an option in Notion feeds the parser directly.
NOTION_TOKEN="$NOTION_TOKEN" PARENT="$NOTION_PARENT_PAGE_ID" "$PY" - <<'PYEOF' > "$STATE_FILE.tmp"
import json, os, sys, time, urllib.request

TOKEN  = os.environ["NOTION_TOKEN"]
PARENT = os.environ["PARENT"]
API    = "https://api.notion.com/v1/"

def call(method, path, payload=None, quiet=False):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Notion-Version", "2022-06-28")
    if payload is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(payload).encode()
    for attempt in range(4):                      # basic 429/5xx retry (Notion ~3 req/s)
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(1.2 * (attempt + 1)); continue
            if not quiet:
                sys.stderr.write(e.read().decode() + "\n")
            raise

def rt(): return {"rich_text": {}}
def sel(*names): return {"select": {"options": [{"name": n} for n in names]}}
def rel(dbid): return {"relation": {"database_id": dbid, "single_property": {}}}

# ---- exact IronBank schema. Formulas + the People self-relation are added by
#      PATCH after creation (Notion can't resolve them inside the create call).
def schema_groups():
    return {"Name": {"title": {}}, "Splitwise Group ID": {"number": {}},
            "Allowed": {"checkbox": {}}, "Backfilled": {"checkbox": {}},
            "Last Synced": {"date": {}}}

def schema_swusers():
    return {"Name": {"title": {}}, "Splitwise User ID": {"number": {}},
            "Email": {"email": {}}, "In Groups": rt()}

def schema_people(groups_id, swusers_id):
    return {"Name": {"title": {}},
            "Splitwise Identity": rel(swusers_id),      # the human pick-list
            "Splitwise Name": rt(),                     # readable, poller-filled
            "Splitwise User ID": {"number": {}},        # derived from the pick
            "Default Group": rel(groups_id),            # OPTIONAL: routes into a group
            "Net Balance": {"number": {"format": "rupee"}},
            "Net Balance By Group": rt(),
            "Net Balance Updated": {"date": {}},
            "Aliases": rt(),
            "Candidates": rt(),                         # poller-suggested identity matches
            "Email": {"email": {}},
            "Registration Status": sel("registered", "invited", "dummy")}
            # "Merge Into" (self-relation) is PATCHed in afterwards

def schema_expenses(people_id):
    return {"Description": {"title": {}},
            "Amount": {"number": {"format": "rupee"}},        # YOUR share
            "Total Amount": {"number": {"format": "rupee"}},  # full bill
            "Date": {"date": {}},
            # Month/Year formulas PATCHed in afterwards (they reference Date)
            "Expense Type": sel("Food", "Travel", "Shopping", "Utilities",
                                "Medical", "Entertainment", "Rent", "Groceries", "Other"),
            "Comments": rt(),
            "Payer": rel(people_id),
            "Payment Mode": sel("UPI", "Cash", "Credit Card", "Debit Card", "Unknown"),
            "Source": sel("Telegram", "Telegram Receipt Scanning", "Splitwise", "Manual"),
            "Splitwise ID": rt(), "Splitwise Group ID": rt(), "Splitwise Updated At": rt(),
            "Splits Summary": rt(),
            "Participants": rel(people_id),               # multi via relation
            "Splits Data": rt(),                          # JSON [{person, owed}]
            "Settlement Status": sel("Settled-via-Splitwise", "Needs mapping", "Notion-only"),
            "Sync Action": sel("None", "Delete", "Re-push"),
            "Sync Status": rt()}

# ---- idempotency: inventory existing child databases of the parent page by title
existing = {}
cursor = None
while True:
    path = f"blocks/{PARENT}/children?page_size=100" + (f"&start_cursor={cursor}" if cursor else "")
    r = call("GET", path)
    for b in r["results"]:
        if b["type"] == "child_database":
            existing[b["child_database"]["title"]] = b["id"]
    if not r.get("has_more"): break
    cursor = r["next_cursor"]

# ---- prefer ids from a previous run's state file — survives databases being renamed in
#      Notion (title matching alone would create a duplicate set after a rename).
saved = {}
try:
    with open(".ironbank_onboarding_state.json") as f:
        saved = json.load(f)
except Exception:
    pass

def db_alive(dbid):
    if not dbid:
        return False
    try:
        call("GET", f"databases/{dbid}", quiet=True)
        return True
    except Exception:
        return False

def ensure_db(title, props, icon, state_key):
    """Prefer the state-file id (survives renames), then find by title, else create.
    Existing databases get any missing properties PATCHed in."""
    dbid = saved.get(state_key)
    if dbid and not db_alive(dbid):
        dbid = None
    if not dbid:
        dbid = existing.get(title)
    if dbid:
        db = call("GET", f"databases/{dbid}")
        missing = {k: v for k, v in props.items()
                   if k not in db["properties"] and "title" not in v}
        if missing:
            call("PATCH", f"databases/{dbid}", {"properties": missing})
            sys.stderr.write(f"  ~ {title}: added missing properties: {', '.join(missing)}\n")
        else:
            sys.stderr.write(f"  = {title}: exists, schema OK\n")
        return dbid
    db = call("POST", "databases", {
        "parent": {"type": "page_id", "page_id": PARENT},
        "icon": {"type": "emoji", "emoji": icon},
        "title": [{"type": "text", "text": {"content": title}}],
        "properties": props})
    sys.stderr.write(f"  + {title}: created\n")
    return db["id"]

groups_id   = ensure_db("Groups", schema_groups(), "👥", "NOTION_DB_GROUPS")
swusers_id  = ensure_db("Splitwise Users", schema_swusers(), "📇", "NOTION_DB_SW_USERS")
people_id   = ensure_db("People", schema_people(groups_id, swusers_id), "🧑", "NOTION_DB_PEOPLE")
expenses_id = ensure_db("Expenses", schema_expenses(people_id), "🧾", "NOTION_DB_EXPENSES")

# ---- post-create PATCHes: self-relation + formulas (both idempotent)
pdb = call("GET", f"databases/{people_id}")
if "Merge Into" not in pdb["properties"]:
    call("PATCH", f"databases/{people_id}",
         {"properties": {"Merge Into": rel(people_id)}})
    sys.stderr.write("  ~ People: added Merge Into (self-relation)\n")

edb = call("GET", f"databases/{expenses_id}")
patch = {}
if "Month" not in edb["properties"]:
    patch["Month"] = {"formula": {"expression": 'formatDate(prop("Date"), "YYYY-MM")'}}
if "Year" not in edb["properties"]:
    patch["Year"] = {"formula": {"expression": 'formatDate(prop("Date"), "YYYY")'}}
if patch:
    call("PATCH", f"databases/{expenses_id}", {"properties": patch})
    sys.stderr.write("  ~ Expenses: added Month/Year formulas\n")

json.dump({"NOTION_DB_EXPENSES": expenses_id, "NOTION_DB_PEOPLE": people_id,
           "NOTION_DB_GROUPS": groups_id, "NOTION_DB_SW_USERS": swusers_id},
          sys.stdout, indent=2)
PYEOF
mv "$STATE_FILE.tmp" "$STATE_FILE"
ok "Notion schema provisioned — database ids saved to ${STATE_FILE} (no secrets in it)"

DB_EXPENSES=$("$PY" -c 'import json;print(json.load(open(".ironbank_onboarding_state.json"))["NOTION_DB_EXPENSES"])')
DB_PEOPLE=$("$PY"   -c 'import json;print(json.load(open(".ironbank_onboarding_state.json"))["NOTION_DB_PEOPLE"])')
DB_GROUPS=$("$PY"   -c 'import json;print(json.load(open(".ironbank_onboarding_state.json"))["NOTION_DB_GROUPS"])')
DB_SWUSERS=$("$PY"  -c 'import json;print(json.load(open(".ironbank_onboarding_state.json"))["NOTION_DB_SW_USERS"])')

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 3/6 — Apps Script project + loader (manual, guided)"
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOS'
  1. Open https://script.new  (a standalone Apps Script project — IronBank
     needs NO spreadsheet).
  2. Delete the placeholder code and paste the ENTIRE contents of
     google_apps_script_loader.js from this repository.
  3. Name the project (e.g. "IronBank") and save (Ctrl/Cmd+S).

  The loader fetches the IronBank brain from GitHub on every request, so the
  backend self-updates — you will never paste code again after today.
EOS
# Save the user a copy-paste: put the loader on the clipboard when a tool exists.
if command -v pbcopy >/dev/null 2>&1; then
  pbcopy < google_apps_script_loader.js && ok "google_apps_script_loader.js is on your clipboard — just paste it"
elif command -v clip.exe >/dev/null 2>&1; then
  clip.exe < google_apps_script_loader.js && ok "google_apps_script_loader.js is on your clipboard — just paste it"
elif command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard < google_apps_script_loader.js && ok "google_apps_script_loader.js is on your clipboard — just paste it"
fi
pause

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 4/6 — Secrets → Script Properties (manual — Google has no API for this)"
# ─────────────────────────────────────────────────────────────────────────────
cat <<EOS
  In the Apps Script editor: ⚙ Project Settings → Script Properties → Add:

      Property               Value
      ─────────────────────  ─────────────────────────────────────────────
      TELEGRAM_BOT_TOKEN     (the bot token you entered in step 1)
      GEMINI_API_KEY         (the Gemini key you entered in step 1)
      SPLITWISE_TOKEN        (the Splitwise PAT you entered in step 1)
      NOTION_TOKEN           (the Notion token you entered in step 1)
      GITHUB_TOKEN           (only if you run a private fork)

  Script Properties are the ONLY config store in IronBank — this script will
  add the non-secret keys automatically in the next step.
EOS
read -r -p "  Type 'show' to print the secret values once for pasting, or Enter to skip: " SHOW
if [ "$SHOW" = "show" ]; then
  echo "      TELEGRAM_BOT_TOKEN = ${TELEGRAM_BOT_TOKEN}"
  echo "      GEMINI_API_KEY     = ${GEMINI_API_KEY}"
  echo "      SPLITWISE_TOKEN    = ${SPLITWISE_TOKEN}"
  echo "      NOTION_TOKEN       = ${NOTION_TOKEN}"
  warn "Clear your terminal scrollback after pasting."
fi
pause

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 5/6 — Deploy the Web App, then this script wires config + webhook"
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOS'
  In the Apps Script editor:
  1. Deploy → New deployment → type: Web app
       Execute as:        Me
       Who has access:    Anyone
  2. Authorize when prompted, then COPY the Web app URL
     (looks like https://script.google.com/macros/s/AKfycb.../exec).
EOS
read -r -p "  Paste the Web App URL: " WEBAPP_URL
case "$WEBAPP_URL" in https://script.google.com/*) ;; *) die "That doesn't look like an Apps Script Web App URL." ;; esac

# Verify the deployment is live and the bot token secret landed (ping is auth'd).
# NOTE: no -X POST — --data already makes this a POST, and Apps Script answers POSTs with a
# 302 whose echo URL must be fetched with GET (forcing POST on the redirect breaks it).
PING=$(curl -sL "$WEBAPP_URL" \
  --data-urlencode "action=ping" \
  --data-urlencode "secret=${TELEGRAM_BOT_TOKEN}")
case "$PING" in
  *'"ok":true'*) ok "Deployment is live (ping OK)" ;;
  *'Unauthorized'*) die "Deployment is live but TELEGRAM_BOT_TOKEN in Script Properties doesn't match — fix step 4 and re-run." ;;
  *) die "Ping failed — is the Web App deployed with access 'Anyone'? Response: $PING" ;;
esac

# Push each NON-SECRET key into Script Properties via the Web App's updateConfig
# action (auth: secret = bot token; -L follows Apps Script's 302 redirect).
push_cfg() { # push_cfg KEY VALUE  (no -X POST — see the ping note above)
  local out
  out=$(curl -sL "$WEBAPP_URL" \
        --data-urlencode "action=updateConfig" \
        --data-urlencode "secret=${TELEGRAM_BOT_TOKEN}" \
        --data-urlencode "key=$1" \
        --data-urlencode "value=$2")
  case "$out" in *'"success":true'*) ok "Config: $1" ;;
    *) die "Failed to set $1 — response: $out" ;;
  esac
}

push_cfg "OWNER_NAME"            "$OWNER_NAME"
push_cfg "NOTION_DB_EXPENSES"    "$DB_EXPENSES"
push_cfg "NOTION_DB_PEOPLE"      "$DB_PEOPLE"
push_cfg "NOTION_DB_GROUPS"      "$DB_GROUPS"
push_cfg "NOTION_DB_SW_USERS"    "$DB_SWUSERS"
push_cfg "NOTION_PARENT_PAGE_ID" "$NOTION_PARENT_PAGE_ID"
push_cfg "SCHEMA_VERSION"        "$SCHEMA_VERSION"
push_cfg "TELEGRAM_CHAT_ID"      "$TELEGRAM_CHAT_ID"
push_cfg "WEBAPP_URL"            "$WEBAPP_URL"   # last: this key also triggers setupWebhook()

# Live-verify every secret you pasted in step 4 through the deployed app. The check runs
# inside Apps Script (pass/fail per key only — values never leave Script Properties).
DIAG=$(curl -sL "$WEBAPP_URL" \
  --data-urlencode "action=diagnose" \
  --data-urlencode "secret=${TELEGRAM_BOT_TOKEN}")
"$PY" - "$DIAG" <<'PYEOF' || die "Fix the failing value(s) in Script Properties (step 4), then re-run this script — every step is idempotent."
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  ! diagnose returned an unexpected response: " + sys.argv[1][:200]); sys.exit(1)
checks = d.get("checks", {})
labels = [("telegram", "TELEGRAM_BOT_TOKEN"), ("gemini", "GEMINI_API_KEY"),
          ("splitwise", "SPLITWISE_TOKEN"), ("notion", "NOTION_TOKEN (+ database ids)")]
bad = False
for key, label in labels:
    good = bool(checks.get(key))
    print(("  \033[32m✓\033[0m " if good else "  \033[31m✗\033[0m ") + label + ("" if good else "   <-- failing"))
    bad = bad or not good
sys.exit(1 if bad else 0)
PYEOF

# Install the 15-min sync trigger through the Web App (it executes as you — the script's
# own authorized context — so no editor visit is needed).
TRG=$(curl -sL "$WEBAPP_URL" \
  --data-urlencode "action=installTrigger" \
  --data-urlencode "secret=${TELEGRAM_BOT_TOKEN}")
case "$TRG" in
  *'"success":true'*) ok "Sync trigger installed (pollSplitwise, time-driven)" ;;
  *) warn "Couldn't install the trigger automatically — fallback: run installPollTrigger once in the Apps Script editor. Response: $TRG" ;;
esac

# Run the first sync now, so Groups + contacts are already in Notion when you open it.
echo "  Running the first Splitwise ↔ Notion sync (can take a minute)..."
SYNC=$(curl -sL --max-time 360 "$WEBAPP_URL" \
  --data-urlencode "action=sync" \
  --data-urlencode "secret=${TELEGRAM_BOT_TOKEN}")
case "$SYNC" in
  *'"ok":true'*) ok "First sync complete — your Splitwise groups and contacts are in Notion" ;;
  *) warn "First sync didn't finish cleanly (the trigger will retry it): ${SYNC:0:160}" ;;
esac

# Verify the webhook actually landed on Telegram's side.
WH=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo")
case "$WH" in
  *"script.google.com"*) ok "Telegram webhook registered → Apps Script (with a per-instance secret)" ;;
  *) warn "Webhook not visible yet — run setupWebhook() once from the Apps Script editor." ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
bold "STEP 6/6 — First contact + build the views (last mile)"
# ─────────────────────────────────────────────────────────────────────────────
cat <<EOS
  1. FIRST CONTACT: message your bot  @${BOT_USER}  right now — e.g. "/help".
     Only your pinned chat id (${TELEGRAM_CHAT_ID}) can talk to it.

  2. GROUPS: your Splitwise groups are already in the Notion "Groups"
     database (the first sync just ran). Tick  Allowed  on the ones to
     import — each gets a one-time history backfill, then stays current.

  3. PEOPLE: as names appear in "People", set each person's Splitwise
     Identity (a dropdown fed by the Splitwise Users contacts DB — check the
     Candidates column for suggested matches). Default Group is optional:
     leave it empty to settle with them as direct friend expenses.

  4. VIEWS: if your Notion page already shows sections like "Balances at a
     Glance" and "Needs Your Attention" (from duplicating the template),
     you're done — skip this. Otherwise (manual — the Notion API cannot create
     views): build the dashboard once. Open  dashboard_build_guide.html  from
     this repository in your browser — it tracks your progress as you build
     (DASHBOARD.md is the plain-text version of the same guide).

  Smoke test: send  "100 chai me and <a friend>"  to @${BOT_USER} — you should
  get a parsed split reply, a row in Notion Expenses, and (once that friend
  has a Splitwise Identity) a Splitwise expense. /status shows sync health.
EOS

bold "Done. Non-secret state saved in ${STATE_FILE}. Re-run this script any time — every step is idempotent."
