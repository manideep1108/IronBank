#!/usr/bin/env python3
# ============================================================================
#  IronBank - onboarding (fully cloud-hosted; nothing runs on your machine)
#
#      Telegram bot --> Google Apps Script --> Notion (record + dashboard)
#                                          \-> Splitwise (settlement)
#
#  Cross-platform: runs the same on Windows (cmd/PowerShell), macOS, and Linux.
#  The ONLY requirement is Python 3.7+ (which you're already running). No bash,
#  no curl, no Git Bash, no extra pip installs - everything below uses the
#  Python standard library.
#
#  What this script DOES (automated):
#    1. Collects + live-validates all four credentials (Telegram bot token,
#       Gemini key, Splitwise PAT, Notion token+page) and pins your Telegram
#       chat id (required - prevents bot hijack).
#    2. Provisions the 4 Notion databases (Expenses / People / Groups /
#       Splitwise Users) IDEMPOTENTLY - including the Month/Year formulas,
#       all relations, and the seeded Expense Type / Payment Mode options that
#       drive the parser. Re-runs prefer the database ids saved in the state
#       file (survives renames), then fall back to title matching.
#    3. After you deploy the Apps Script Web App, pushes all NON-SECRET config
#       into Script Properties through the Web App's updateConfig action, and
#       registers the Telegram webhook.
#    4. LIVE-VERIFIES every secret you pasted (diagnose - pass/fail only,
#       values never leave Apps Script), INSTALLS the 15-min sync trigger
#       through the Web App, and RUNS THE FIRST SYNC so your Splitwise groups
#       and contacts are already in Notion when you open it.
#
#  What it CANNOT automate (guided manual steps - no API exists for them):
#    A. Creating the Apps Script project (script.new) + pasting the loader
#       (this script copies the loader to your clipboard when it can).
#    B. Setting the four SECRETS in Script Properties (Google offers no public
#       API for Script Properties - and that's where secrets belong).
#    C. Deploying the Web App (interactive Google authorization).
#    D. Sharing the Notion parent page with your integration.
#    E. Building the Notion VIEWS - the Notion API cannot create views. Follow
#       dashboard_build_guide.html (or DASHBOARD.md) once at the end.
#
#  There is NO Google Sheet in IronBank: all config lives in Script Properties,
#  logs live in the Apps Script execution log.
#
#  Run it:  python onboarding.py     (or: python3 onboarding.py)
#  Safe to re-run at any point; never prints secrets unless you ask.
# ============================================================================
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if sys.version_info < (3, 7):
    sys.stderr.write("Python 3.7+ is required. You're on %s.\n" % sys.version.split()[0])
    sys.exit(1)

# Force UTF-8 output so status glyphs (checkmarks etc.) never crash on Windows,
# where a redirected stream or a legacy console codepage (cp1252) otherwise
# raises UnicodeEncodeError. errors="replace" degrades gracefully if a terminal
# still can't render a glyph, instead of aborting the whole run.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(SCRIPT_DIR, ".ironbank_onboarding_state.json")
LOADER_FILE = os.path.join(SCRIPT_DIR, "google_apps_script_loader.js")
SCHEMA_VERSION = "1"                # stamped into config for future schema migrations
NOTION_VERSION = "2022-06-28"
# Some APIs (Splitwise, behind Cloudflare) 403 the default "Python-urllib/x.y"
# User-Agent as a suspected bot. A real UA sails through — set it on every request.
USER_AGENT = "IronBank-Onboarding/1.0"

# ── color / tty setup ────────────────────────────────────────────────────────
_USE_COLOR = sys.stdout.isatty()
if _USE_COLOR and os.name == "nt":
    # Enable ANSI escape processing on the Windows console (Win10+). If it fails,
    # fall back to plain text - the script still works, just without color.
    try:
        import ctypes
        _k = ctypes.windll.kernel32
        _h = _k.GetStdHandle(-11)          # STD_OUTPUT_HANDLE
        _mode = ctypes.c_uint32()
        if _k.GetConsoleMode(_h, ctypes.byref(_mode)):
            _k.SetConsoleMode(_h, _mode.value | 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        else:
            _USE_COLOR = False
    except Exception:
        _USE_COLOR = False


def _c(code, text):
    return ("\033[%sm%s\033[0m" % (code, text)) if _USE_COLOR else text


def bold(msg):  print(_c("1", msg))
def ok(msg):    print("  " + _c("32", "✓") + " " + msg)
def warn(msg):  print("  " + _c("33", "!") + " " + msg)
def info(msg):  print(msg)


def die(msg):
    sys.stdout.flush()   # keep the error ordered after preceding output when redirected
    sys.stderr.write("  " + _c("31", "✗ " + msg) + "\n")
    sys.exit(1)


def pause():
    print()
    try:
        input("  ↩  Press Enter when done... ")
    except EOFError:
        pass


def ask(env_key, label, secret=False):
    """Prompt for a value, preferring an already-set environment variable
    (lets you script/re-run this non-interactively). Required - dies if empty."""
    cur = os.environ.get(env_key, "").strip()
    if cur:
        ok("%s - using value from $%s" % (label, env_key))
        return cur
    try:
        if secret:
            import getpass
            val = getpass.getpass("  %s: " % label).strip()
        else:
            val = input("  %s: " % label).strip()
    except EOFError:
        val = ""
    if not val:
        die("%s is required." % label)
    return val


# ── HTTP helpers (stdlib only) ───────────────────────────────────────────────
def http_json(url, headers=None, method="GET", timeout=30):
    """GET/POST returning parsed JSON. Raises on any non-2xx (like curl -f)."""
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", USER_AGENT)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def web_app_post(url, params, timeout=60):
    """POST form-encoded to the Apps Script Web App and return the body text.
    Apps Script answers POSTs with a 302 whose target must be fetched with GET;
    urllib follows that redirect as GET by default (matching curl -L). Errors are
    swallowed into the returned text so callers can pattern-match like the old
    shell version did."""
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(url, data=data)   # presence of data => POST
    req.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.read().decode("utf-8", "replace")
        except Exception:
            return "HTTPError %s" % e.code
    except Exception as e:
        return "ERROR: %s" % e


def copy_to_clipboard(text):
    """Best-effort copy across platforms. Returns True on success."""
    if sys.platform == "darwin":
        tools = [["pbcopy"]]
    elif os.name == "nt":
        tools = [["clip"]]
    else:
        tools = [["wl-copy"], ["xclip", "-selection", "clipboard"],
                 ["xsel", "--clipboard", "--input"]]
    for t in tools:
        try:
            subprocess.run(t, input=text.encode("utf-8"), check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            continue
    return False


# ── Notion API (with basic 429/5xx retry, ~3 req/s) ──────────────────────────
NOTION_TOKEN = ""   # set after step 1


def notion(method, path, payload=None, quiet=False):
    req = urllib.request.Request("https://api.notion.com/v1/" + path, method=method)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Authorization", "Bearer " + NOTION_TOKEN)
    req.add_header("Notion-Version", NOTION_VERSION)
    if payload is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(payload).encode()
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(1.2 * (attempt + 1))
                continue
            if not quiet:
                try:
                    sys.stderr.write(e.read().decode() + "\n")
                except Exception:
                    pass
            raise


def rt():            return {"rich_text": {}}
def sel(*names):     return {"select": {"options": [{"name": n} for n in names]}}
def rel(dbid):       return {"relation": {"database_id": dbid, "single_property": {}}}


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


def provision_notion(parent):
    """Idempotently ensure the 4 databases exist under the parent page and return
    their ids. Prefers state-file ids (survives renames), then existing child
    databases by exact title, else creates. Missing properties are PATCHed in."""
    # inventory existing child databases of the parent page by title
    existing = {}
    cursor = None
    while True:
        path = "blocks/%s/children?page_size=100" % parent + (("&start_cursor=" + cursor) if cursor else "")
        r = notion("GET", path)
        for b in r["results"]:
            if b["type"] == "child_database":
                existing[b["child_database"]["title"]] = b["id"]
        if not r.get("has_more"):
            break
        cursor = r["next_cursor"]

    # prefer ids from a previous run's state file - survives renames in Notion
    saved = {}
    try:
        with open(STATE_FILE) as f:
            saved = json.load(f)
    except Exception:
        pass

    def db_alive(dbid):
        if not dbid:
            return False
        try:
            notion("GET", "databases/%s" % dbid, quiet=True)
            return True
        except Exception:
            return False

    def ensure_db(title, props, icon, state_key):
        dbid = saved.get(state_key)
        if dbid and not db_alive(dbid):
            dbid = None
        if not dbid:
            dbid = existing.get(title)
        if dbid:
            db = notion("GET", "databases/%s" % dbid)
            missing = {k: v for k, v in props.items()
                       if k not in db["properties"] and "title" not in v}
            if missing:
                notion("PATCH", "databases/%s" % dbid, {"properties": missing})
                print("  ~ %s: added missing properties: %s" % (title, ", ".join(missing)))
            else:
                print("  = %s: exists, schema OK" % title)
            return dbid
        db = notion("POST", "databases", {
            "parent": {"type": "page_id", "page_id": parent},
            "icon": {"type": "emoji", "emoji": icon},
            "title": [{"type": "text", "text": {"content": title}}],
            "properties": props})
        print("  + %s: created" % title)
        return db["id"]

    groups_id   = ensure_db("Groups", schema_groups(), "\U0001F465", "NOTION_DB_GROUPS")
    swusers_id  = ensure_db("Splitwise Users", schema_swusers(), "\U0001F4C7", "NOTION_DB_SW_USERS")
    people_id   = ensure_db("People", schema_people(groups_id, swusers_id), "\U0001F9D1", "NOTION_DB_PEOPLE")
    expenses_id = ensure_db("Expenses", schema_expenses(people_id), "\U0001F9FE", "NOTION_DB_EXPENSES")

    # post-create PATCHes: self-relation + formulas (both idempotent)
    pdb = notion("GET", "databases/%s" % people_id)
    if "Merge Into" not in pdb["properties"]:
        notion("PATCH", "databases/%s" % people_id, {"properties": {"Merge Into": rel(people_id)}})
        print("  ~ People: added Merge Into (self-relation)")

    edb = notion("GET", "databases/%s" % expenses_id)
    patch = {}
    if "Month" not in edb["properties"]:
        patch["Month"] = {"formula": {"expression": 'formatDate(prop("Date"), "YYYY-MM")'}}
    if "Year" not in edb["properties"]:
        patch["Year"] = {"formula": {"expression": 'formatDate(prop("Date"), "YYYY")'}}
    if patch:
        notion("PATCH", "databases/%s" % expenses_id, {"properties": patch})
        print("  ~ Expenses: added Month/Year formulas")

    ids = {"NOTION_DB_EXPENSES": expenses_id, "NOTION_DB_PEOPLE": people_id,
           "NOTION_DB_GROUPS": groups_id, "NOTION_DB_SW_USERS": swusers_id}
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ids, f, indent=2)
    os.replace(tmp, STATE_FILE)
    return ids


# ============================================================================
def main():
    global NOTION_TOKEN

    bold("IronBank onboarding - Telegram -> Apps Script -> Notion + Splitwise")
    info("  Everything runs in Google/Notion/Splitwise clouds. No local server, no Google Sheet.")
    info("  NOTE: IronBank is INR-only today (non-INR Splitwise groups/expenses are excluded by design).")
    print()

    # ── STEP 1 ────────────────────────────────────────────────────────────────
    bold("STEP 1/6 - Credentials (each is validated live before we continue)")
    info("  - Telegram bot token  -> create a bot with @BotFather, copy the token")
    info("  - Gemini API key      -> https://aistudio.google.com/apikey")
    info("  - Splitwise PAT       -> https://secure.splitwise.com/apps -> Register app -> Personal Access Token")
    info("  - Notion token        -> https://www.notion.so/my-integrations -> New integration (internal)")
    info("  - Notion parent page  -> recommended: duplicate the IronBank template into your workspace")
    info("                          (https://app.notion.com/p/IronBank-Template-3a3f0556bd7e80bfb29fd0c67e04168a),")
    info("                          then use YOUR copy's page. Or share any blank page - the script")
    info("                          creates the databases from scratch either way. SHARE the page with")
    info("                          the integration first: page ... menu -> Connections -> your integration")
    print()

    telegram_token = ask("TELEGRAM_BOT_TOKEN", "Telegram bot token", secret=True)
    try:
        tg_me = http_json("https://api.telegram.org/bot%s/getMe" % telegram_token)
        bot_user = tg_me["result"]["username"]
    except Exception:
        die("Telegram rejected that bot token (getMe failed).")
    ok("Telegram bot verified: @%s" % bot_user)

    gemini_key = ask("GEMINI_API_KEY", "Gemini API key", secret=True)
    try:
        http_json("https://generativelanguage.googleapis.com/v1beta/models?key=%s" % gemini_key)
    except Exception:
        die("Gemini rejected that API key.")
    ok("Gemini key verified")

    splitwise_token = ask("SPLITWISE_TOKEN", "Splitwise Personal Access Token", secret=True)
    try:
        sw_me = http_json("https://secure.splitwise.com/api/v3.0/get_current_user",
                          headers={"Authorization": "Bearer " + splitwise_token})
        sw_first = sw_me["user"].get("first_name") or ""
        sw_id = sw_me["user"]["id"]
    except Exception:
        die("Splitwise rejected that token (get_current_user failed).")
    ok("Splitwise verified: %s (user id %s)" % (sw_first, sw_id))

    NOTION_TOKEN = ask("NOTION_TOKEN", "Notion integration token", secret=True)
    parent_raw = ask("NOTION_PARENT_PAGE_ID", "Notion parent page id or full page URL")
    # Accept a bare id, a dashed UUID, or a full page URL. Drop any ?query/#fragment
    # first (e.g. the template's ?source=copy_link) so its trailing hex chars can't
    # shift the 32-char window, then take the last 32 hex chars and re-dash.
    parent_clean = parent_raw.split("?", 1)[0].split("#", 1)[0]
    s = re.sub(r"[^0-9a-fA-F]", "", parent_clean)[-32:]
    parent = ("%s-%s-%s-%s-%s" % (s[0:8], s[8:12], s[12:16], s[16:20], s[20:32])) if len(s) == 32 else parent_raw
    try:
        http_json("https://api.notion.com/v1/pages/%s" % parent,
                  headers={"Authorization": "Bearer " + NOTION_TOKEN, "Notion-Version": NOTION_VERSION})
    except Exception:
        die("Notion can't read that page - wrong id, or the page isn't shared with the integration (manual step D).")
    ok("Notion token + parent page verified")

    # Owner name: what 'me/I/my' resolve to. Default = Splitwise first name.
    default_owner = sw_first or "Owner"
    owner_env = os.environ.get("OWNER_NAME", "").strip()
    if owner_env:
        owner_name = owner_env
    else:
        try:
            owner_name = input("  Your name as the bot should know you [%s]: " % default_owner).strip() or default_owner
        except EOFError:
            owner_name = default_owner
    ok("Owner name: %s" % owner_name)

    # REQUIRED: pin your Telegram chat id (prevents anyone else claiming your bot).
    print()
    info("  Pin your Telegram chat id (required - prevents anyone else claiming your bot).")
    info("  Get your numeric id by messaging @userinfobot on Telegram.")
    chat_env = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if chat_env:
        ok("Telegram chat id - using value from $TELEGRAM_CHAT_ID")
        chat_id = chat_env
    else:
        while True:
            try:
                chat_id = input("  Your Telegram chat id (numeric): ").strip()
            except EOFError:
                chat_id = ""
            if chat_id and re.fullmatch(r"-?[0-9]+", chat_id):
                break
            warn("That doesn't look like a numeric chat id (e.g. 123456789) - try again.")
    ok("Chat id pinned: %s" % chat_id)

    # ── STEP 2 ────────────────────────────────────────────────────────────────
    print()
    bold("STEP 2/6 - Link the 4 Notion databases (idempotent)")
    # If Groups / Splitwise Users / People / Expenses already exist under the
    # parent page (e.g. you duplicated the template), they're found by exact
    # title and reused - nothing is created or duplicated. Only missing databases
    # are created from scratch. Missing properties on an existing (possibly older)
    # template are PATCHed in, self-healing schema drift.
    try:
        ids = provision_notion(parent)
    except Exception as e:
        die("Notion provisioning failed: %s" % e)
    ok("Notion schema provisioned - database ids saved to %s (no secrets in it)" % os.path.basename(STATE_FILE))

    db_expenses = ids["NOTION_DB_EXPENSES"]
    db_people   = ids["NOTION_DB_PEOPLE"]
    db_groups   = ids["NOTION_DB_GROUPS"]
    db_swusers  = ids["NOTION_DB_SW_USERS"]

    # ── STEP 3 ────────────────────────────────────────────────────────────────
    print()
    bold("STEP 3/6 - Apps Script project + loader (manual, guided)")
    info("""  1. Open https://script.new  (a standalone Apps Script project - IronBank
     needs NO spreadsheet).
  2. Delete the placeholder code and paste the ENTIRE contents of
     google_apps_script_loader.js from this repository.
  3. Name the project (e.g. "IronBank") and save (Ctrl/Cmd+S).

  The loader fetches the IronBank brain from GitHub on every request, so the
  backend self-updates - you will never paste code again after today.""")
    try:
        with open(LOADER_FILE, encoding="utf-8") as f:
            loader_src = f.read()
        if copy_to_clipboard(loader_src):
            ok("google_apps_script_loader.js is on your clipboard - just paste it")
    except Exception:
        pass  # clipboard is a convenience; the file is right there in the repo
    pause()

    # ── STEP 4 ────────────────────────────────────────────────────────────────
    print()
    bold("STEP 4/6 - Secrets -> Script Properties (manual - Google has no API for this)")
    info("""  In the Apps Script editor: Project Settings -> Script Properties -> Add:

      Property               Value
      ---------------------  ---------------------------------------------
      TELEGRAM_BOT_TOKEN     (the bot token you entered in step 1)
      GEMINI_API_KEY         (the Gemini key you entered in step 1)
      SPLITWISE_TOKEN        (the Splitwise PAT you entered in step 1)
      NOTION_TOKEN           (the Notion token you entered in step 1)
      GITHUB_TOKEN           (only if you run a private fork)

  Script Properties are the ONLY config store in IronBank - this script will
  add the non-secret keys automatically in the next step.""")
    try:
        show = input("  Type 'show' to print the secret values once for pasting, or Enter to skip: ").strip()
    except EOFError:
        show = ""
    if show == "show":
        info("      TELEGRAM_BOT_TOKEN = %s" % telegram_token)
        info("      GEMINI_API_KEY     = %s" % gemini_key)
        info("      SPLITWISE_TOKEN    = %s" % splitwise_token)
        info("      NOTION_TOKEN       = %s" % NOTION_TOKEN)
        warn("Clear your terminal scrollback after pasting.")
    pause()

    # ── STEP 5 ────────────────────────────────────────────────────────────────
    print()
    bold("STEP 5/6 - Deploy the Web App, then this script wires config + webhook")
    info("""  In the Apps Script editor:
  1. Deploy -> New deployment -> type: Web app
       Execute as:        Me
       Who has access:    Anyone
  2. Authorize when prompted, then COPY the Web app URL
     (looks like https://script.google.com/macros/s/AKfycb.../exec).""")
    try:
        webapp_url = input("  Paste the Web App URL: ").strip()
    except EOFError:
        webapp_url = ""
    if not webapp_url.startswith("https://script.google.com/"):
        die("That doesn't look like an Apps Script Web App URL.")

    # Verify the deployment is live and the bot token secret landed (ping is auth'd).
    ping = web_app_post(webapp_url, {"action": "ping", "secret": telegram_token})
    if '"ok":true' in ping:
        ok("Deployment is live (ping OK)")
    elif "Unauthorized" in ping:
        die("Deployment is live but TELEGRAM_BOT_TOKEN in Script Properties doesn't match - fix step 4 and re-run.")
    else:
        die("Ping failed - is the Web App deployed with access 'Anyone'? Response: %s" % ping)

    # Push each NON-SECRET key into Script Properties via the Web App's updateConfig.
    def push_cfg(key, value):
        out = web_app_post(webapp_url, {"action": "updateConfig", "secret": telegram_token,
                                        "key": key, "value": value})
        if '"success":true' in out:
            ok("Config: %s" % key)
        else:
            die("Failed to set %s - response: %s" % (key, out))

    push_cfg("OWNER_NAME", owner_name)
    push_cfg("NOTION_DB_EXPENSES", db_expenses)
    push_cfg("NOTION_DB_PEOPLE", db_people)
    push_cfg("NOTION_DB_GROUPS", db_groups)
    push_cfg("NOTION_DB_SW_USERS", db_swusers)
    push_cfg("NOTION_PARENT_PAGE_ID", parent)
    push_cfg("SCHEMA_VERSION", SCHEMA_VERSION)
    push_cfg("TELEGRAM_CHAT_ID", chat_id)
    push_cfg("WEBAPP_URL", webapp_url)   # last: this key also triggers setupWebhook()

    # Live-verify every secret you pasted in step 4 through the deployed app.
    diag = web_app_post(webapp_url, {"action": "diagnose", "secret": telegram_token})
    try:
        d = json.loads(diag)
    except Exception:
        die("diagnose returned an unexpected response: %s" % diag[:200])
    checks = d.get("checks", {})
    labels = [("telegram", "TELEGRAM_BOT_TOKEN"), ("gemini", "GEMINI_API_KEY"),
              ("splitwise", "SPLITWISE_TOKEN"), ("notion", "NOTION_TOKEN (+ database ids)")]
    bad = False
    for key, label in labels:
        good = bool(checks.get(key))
        mark = _c("32", "✓") if good else _c("31", "✗")
        print("  " + mark + " " + label + ("" if good else "   <-- failing"))
        bad = bad or not good
    if bad:
        die("Fix the failing value(s) in Script Properties (step 4), then re-run this script - every step is idempotent.")

    # Install the 15-min sync trigger through the Web App.
    trg = web_app_post(webapp_url, {"action": "installTrigger", "secret": telegram_token})
    if '"success":true' in trg:
        ok("Sync trigger installed (pollSplitwise, time-driven)")
    else:
        warn("Couldn't install the trigger automatically - fallback: run installPollTrigger once in the Apps Script editor. Response: %s" % trg)

    # Run the first sync now, so Groups + contacts are already in Notion.
    info("  Running the first Splitwise <-> Notion sync (can take a minute)...")
    sync = web_app_post(webapp_url, {"action": "sync", "secret": telegram_token}, timeout=360)
    if '"ok":true' in sync:
        ok("First sync complete - your Splitwise groups and contacts are in Notion")
    else:
        warn("First sync didn't finish cleanly (the trigger will retry it): %s" % sync[:160])

    # Verify the webhook actually landed on Telegram's side.
    try:
        wh = http_json("https://api.telegram.org/bot%s/getWebhookInfo" % telegram_token)
        wh_text = json.dumps(wh)
    except Exception:
        wh_text = ""
    if "script.google.com" in wh_text:
        ok("Telegram webhook registered -> Apps Script (with a per-instance secret)")
    else:
        warn("Webhook not visible yet - run setupWebhook() once from the Apps Script editor.")

    # ── STEP 6 ────────────────────────────────────────────────────────────────
    print()
    bold("STEP 6/6 - First contact + build the views (last mile)")
    info("""  1. FIRST CONTACT: message your bot  @%s  right now - e.g. "/help".
     Only your pinned chat id (%s) can talk to it.

  2. GROUPS: your Splitwise groups are already in the Notion "Groups"
     database (the first sync just ran). Tick  Allowed  on the ones to
     import - each gets a one-time history backfill, then stays current.

  3. PEOPLE: as names appear in "People", set each person's Splitwise
     Identity (a dropdown fed by the Splitwise Users contacts DB - check the
     Candidates column for suggested matches). Default Group is optional:
     leave it empty to settle with them as direct friend expenses.

  4. VIEWS: if your Notion page already shows sections like "Balances at a
     Glance" and "Needs Your Attention" (from duplicating the template),
     you're done - skip this. Otherwise (manual - the Notion API cannot create
     views): build the dashboard once. Open  dashboard_build_guide.html  from
     this repository in your browser - it tracks your progress as you build
     (DASHBOARD.md is the plain-text version of the same guide).

  Smoke test: send  "100 chai me and <a friend>"  to @%s - you should
  get a parsed split reply, a row in Notion Expenses, and (once that friend
  has a Splitwise Identity) a Splitwise expense. /status shows sync health.""" % (bot_user, chat_id, bot_user))

    print()
    bold("Done. Non-secret state saved in %s. Re-run this script any time - every step is idempotent."
         % os.path.basename(STATE_FILE))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.stderr.write("\n  Aborted.\n")
        sys.exit(130)
