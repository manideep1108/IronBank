# 🏦 IronBank

**Message a Telegram bot in plain language — get a categorized ledger in Notion and settled balances in Splitwise.**

IronBank is a self-hosted, single-tenant expense splitter that runs entirely in clouds you already use. There is no server to run, no database to babysit, and nothing to install on your machine: the "backend" is one Google Apps Script, the ledger is Notion, and settlement is Splitwise.

```
CAPTURE    Telegram  (text: "800 dinner, me and Aditya" — or a receipt photo)
              │
COMPUTE    Google Apps Script — the brain (google_apps_script.js)
              │   • Gemini parses the message / receipt
              │   • names resolve against your Notion People (aliases, learning, ask-on-ambiguity)
              │   • splits are computed deterministically in code
              │   • the expense is WRITTEN to Notion and PUSHED to Splitwise
              │
SYNC-BACK  a 15-minute trigger (pollSplitwise) pulls Splitwise back into Notion:
              │   group + friend expenses, contacts, live balances, and any
              │   actions you flagged in Notion (identity picks, merges, deletes)
              │
RECORD     Notion    — 4 databases + your hand-built views  (system of record)
SETTLE     Splitwise — native settlement + authoritative balances
```

## What it does

- **Natural-language capture** — `100 for taxi today via UPI`, `dinner 900 split equally between me, Alice and Bob`, `800 groceries — Alice had 300, we split the rest`. Math expressions (`793-245`) are evaluated in code, not by the AI.
- **Receipt scanning** — send a photo (with an optional caption for split instructions); Gemini reads the merchant, date, and total.
- **Smart name resolution** — nicknames and typos resolve against your Notion People roster; genuinely ambiguous names ("Adi" → Aditya or Aditi?) get inline Telegram buttons; confirmed nicknames are learned as aliases and never asked again.
- **Automatic Splitwise settlement** — each participant is routed to their default Splitwise group, or settled as a direct friend expense if they have none. One expense can span several groups; you always see exactly who owes what in the bot's reply.
- **Everything lands in Notion** — one row per expense with your share, the full bill, category, payment mode, participants, and settlement status. Your Splitwise activity (including expenses *others* paid) flows in automatically and is auto-categorized by Gemini against your Notion category list.
- **Live balances** — every sync refreshes each person's net balance from Splitwise. `/settle` in Telegram or the Balances view in Notion answers "who owes whom" at any moment.
- **Bot commands** — `/report` (monthly spend by category), `/settle` (balances), `/sync` (run the sync now), `/status` (sync health + what needs attention), `/help`.

## The two rules

1. **You must be the payer.** IronBank only records expenses *you* paid. If someone else paid, they log it on their own IronBank (or straight in Splitwise) and it arrives in your Notion via sync. This is what guarantees one real expense → exactly one Splitwise entry, even when several people run IronBank independently.
2. **INR only.** Non-INR Splitwise groups and expenses are excluded by design.

## Setup (~20 minutes, once)

**Step 0 — start from the Notion template (recommended).** Open the [IronBank Notion template](https://app.notion.com/p/IronBank-Template-3a3f0556bd7e80bfb29fd0c67e04168a?source=copy_link), click **Duplicate** into your own workspace, then share *your copy* with your Notion integration (page ••• menu → Connections). Copy your duplicated page's URL — you'll paste it when the script asks for your Notion parent page. The 4 databases and the dashboard views come pre-built, empty, and ready to go; the script detects them by name and reuses them instead of creating new ones.

Don't want to use the template? Share any blank page instead — the script will create the databases from scratch, and you'll build the dashboard views yourself at the end (see the last row below).

```bash
git clone https://github.com/manideep1108/IronBank.git
cd IronBank
python onboarding.py
```

Onboarding is a single Python script — **the same command on Windows, macOS, and Linux**. The only requirement is **Python 3.7+** (already on most Macs/Linux; on Windows install it from [python.org](https://www.python.org/downloads/windows/) and tick **"Add python.exe to PATH"**). No bash, curl, or Git Bash needed — it uses only Python's standard library. On some systems Python is `python3` rather than `python` (`python3 onboarding.py`); on Unix-likes `./onboarding.sh` still works as a thin shim that just calls it.

**No git?** Use the green **Code → Download ZIP** button on GitHub instead, extract it, and run `python onboarding.py` from inside the extracted folder. Everything else is identical — and because it's launched via `python`, there's no executable-bit issue like shell scripts have from ZIP downloads.

The script walks you through everything and automates what can be automated:

| Step | Automated? | What happens |
|---|---|---|
| Collect + validate credentials | ✅ | Telegram bot token, Gemini API key, Splitwise Personal Access Token, Notion integration token + parent page — each verified live. Your Telegram chat id is pinned up front (required — prevents bot hijack) |
| Provision the 4 Notion databases | ✅ | Idempotent — detects databases already there (e.g. from duplicating the template) by name and pulls their ids; only creates from scratch, with the exact schema/formulas/relations, if they don't exist yet |
| Apps Script project + loader paste | 🖐 guided | [script.new](https://script.new), paste `google_apps_script_loader.js` once (the script puts it on your clipboard) |
| Bootstrap secret → Script Properties | 🖐 guided | You set **only** `TELEGRAM_BOT_TOKEN` by hand (Google has no API for Script Properties, and this is the key the config API authenticates with — so it must exist first). The script offers to copy the name + value to your clipboard so it's paste-only |
| Deploy the Web App | 🖐 guided | Execute as **Me**, access **Anyone** |
| Push remaining secrets + config + webhook | ✅ | Once the bot token is in and the Web App is deployed, the script pushes the other three secrets (Gemini, Splitwise, Notion) plus all non-secret config through the deployed Web App's `updateConfig` (values never logged); webhook registered with a per-instance secret |
| Verify the pasted secrets | ✅ | `diagnose` live-tests every secret inside Apps Script and reports pass/fail per key — a typo'd token is caught immediately, not at the first silent sync failure |
| Install the 15-min sync trigger | ✅ | Installed through the Web App (it executes as you); fallback: run `installPollTrigger` in the editor |
| Run the first sync | ✅ | Your Splitwise groups + contacts are already in Notion before the script exits |
| Build the Notion views | 🖐 once, skip if using the template | The Notion API cannot create views — open [dashboard_build_guide.html](dashboard_build_guide.html) (or [DASHBOARD.md](DASHBOARD.md)). Already done for you if you duplicated the template — the views come along with the duplicate |

**Credentials you'll need:** a Telegram bot ([@BotFather](https://t.me/BotFather)), a Gemini API key ([AI Studio](https://aistudio.google.com/apikey)), a Splitwise Personal Access Token ([register an app](https://secure.splitwise.com/apps)), and a Notion internal integration ([my-integrations](https://www.notion.so/my-integrations)) shared to one parent page (your duplicated template, or a blank page).

### Running on Windows

Onboarding runs natively in a plain **Command Prompt** or **PowerShell** window — no Git Bash, no WSL, no wrapper:

1. Install [Python 3](https://www.python.org/downloads/windows/) and tick **"Add python.exe to PATH"** in the installer.
2. In `cmd` or PowerShell:
   ```bat
   git clone https://github.com/manideep1108/IronBank.git
   cd IronBank
   python onboarding.py
   ```
   No git? [Download the ZIP](https://github.com/manideep1108/IronBank), extract it, `cd` into the folder, and run `python onboarding.py`.

Notes: the script copies the Apps Script loader to your clipboard automatically (via `clip`); secret prompts are hidden as you type — paste with right-click or `Ctrl+V` and press Enter (nothing shows on screen, that's expected). Output is forced to UTF-8, so status marks render correctly regardless of your console's codepage.

## Daily use

- **Log:** message the bot. It replies with the parsed split (canonical names — so a wrong guess is immediately visible), a 🗑️ Delete button, and where it settled on Splitwise.
- **Onboard a Splitwise group:** tick `Allowed` on its row in the Notion **Groups** database. The next sync backfills its full history once, then keeps it current.
- **A group you delete (or leave) on Splitwise** disappears from the Notion **Groups** list on the next sync (its row is archived, recoverable from Notion trash). Its already-imported expense rows are kept as history, and anyone who had it as their `Default Group` is quietly unassigned (they then settle directly — pick a new `Default Group` for them if you want group routing).
- **Set up a person:** when a new name appears in **People**, pick their **Splitwise Identity** from the dropdown (the **Candidates** column suggests likely matches). `Default Group` is optional — without it they settle as direct friend expenses. When a person is first imported, if they share **exactly one `Allowed` group** with you, that group is pre-filled as their `Default Group` automatically (you can change or clear it — the sync never overrides your edit).
- **Fix a nickname/stray:** set **Merge Into** on a stray row that has **no Splitwise Identity** (a placeholder the bot made for a nickname it couldn't match); the next sync folds it into the real person, remembers the nickname, and archives the stray.
- **One person, two Splitwise accounts:** don't merge (archiving a live account is pointless — the sync re-imports it). Keep both **People** rows, give the duplicate a distinct name, and set the duplicate's **Primary Identity** to the *primary* account's Splitwise User ID. Outgoing expenses you log then always route to the primary, while the duplicate still imports its own Splitwise activity.
- **Delete/redo an expense:** tap 🗑️ in Telegram, or set **Sync Action** to `Delete` / `Re-push` on the Notion row.
- **Impatient?** `/sync` runs the sync immediately; `/status` shows when it last ran and what's waiting on you.

## The four Notion databases

| Database | Role |
|---|---|
| **Expenses** | The ledger — one row per transaction. `Amount` is *your share*; `Total Amount` is the full bill. `Group` links to the source Splitwise group (shows its name; empty for direct/non-group expenses). `Settlement Status` tells you if it's settled, parked (`Needs mapping`), or Notion-only. |
| **People** | Everyone you actually split with: identity (→ Splitwise Users), aliases, live net balance, optional default group, `Merge Into`. |
| **Groups** | Your Splitwise groups. `Allowed` is the import switch; `Backfilled` marks the one-time history pull. |
| **Splitwise Users** | Your Splitwise address book (friends + all group members), poller-maintained. Read-only — it's the pick-list behind `Splitwise Identity`. |

## Configuration reference

Everything lives in Apps Script **Script Properties** (⚙ Project Settings). You set only `TELEGRAM_BOT_TOKEN` by hand; `onboarding.py` pushes the other secrets and all non-secrets for you.

| Key | Secret? | Purpose |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | 🔒 | The bot + auth for the tiny config API |
| `GEMINI_API_KEY` | 🔒 | Parsing (Gemini 2.5 Flash) |
| `SPLITWISE_TOKEN` | 🔒 | Splitwise v3.0 REST (Personal Access Token) |
| `NOTION_TOKEN` | 🔒 | Notion integration token |
| `GITHUB_TOKEN` | 🔒 | Only for private forks (loader fetch) |
| `OWNER_NAME` | — | Who "me/I/my" resolves to |
| `TELEGRAM_CHAT_ID` | — | The owner's chat. Onboarding pins it up front — otherwise the first chat to message the bot claims ownership |
| `NOTION_DB_EXPENSES` / `_PEOPLE` / `_GROUPS` / `_SW_USERS` | — | Database ids (written by onboarding) |
| `NOTION_PARENT_PAGE_ID` | — | The page holding the 4 databases (written by onboarding) |
| `WEBAPP_URL` | — | The deployment URL; setting it (re)registers the Telegram webhook |
| `POLL_INTERVAL_MIN` | — | Sync cadence in minutes: 1/5/10/15/30 (default 15). Set it, then re-run the trigger install (`installTrigger` action or `installPollTrigger`) |
| `SCHEMA_VERSION` | — | Notion schema generation stamp |

Keys prefixed `POLL_`, `TG_WEBHOOK_SECRET`, `SW_CONTACTS_SIG`, `ROSTER_LAST_GOOD`, and `ironbank_lkg_*` are internal state — leave them alone.

## How updates work (and how to develop)

You paste the **loader** once. On every request it fetches `google_apps_script.js` from this repository's `main` branch (raw), caches it for 10 minutes, and keeps a last-good copy in Script Properties as a fallback. Pushing to `main` **is** deploying to every instance — treat it accordingly:

1. Edit `google_apps_script.js`.
2. Syntax-check before pushing: `python -c "import esprima; esprima.parseScript(open('google_apps_script.js',encoding='utf-8').read())"`.
3. Push. Instances pick it up within ~10 minutes (GitHub raw CDN + loader cache). `doGet` on the Web App URL returns `{ok, version}` for a quick smoke test.

Fork? Point `GITHUB_RAW_URL` in your pasted loader at your fork. **Running a fork that other people use?** Point it at a release **tag**, not `main` — otherwise every push to your `main` executes immediately inside their Google accounts.

## Security notes

- Secrets live only in Script Properties — never in code, Notion, or this repository. During onboarding you type only `TELEGRAM_BOT_TOKEN` in by hand; the other three secrets are sent once, over HTTPS, to your own Web App's authenticated `updateConfig` (which stores them in Script Properties and never logs the value) — the same channel the bot token already authenticates every call with.
- The Telegram webhook is registered with a random per-instance query secret; Telegram-shaped POSTs without it are dropped (Apps Script can't read headers, so this replaces Telegram's native `secret_token`).
- Only the pinned `TELEGRAM_CHAT_ID` can talk to the bot; messages from any other chat are dropped silently (no reply that would confirm the bot exists).
- The Web App exposes no stored data over HTTP: `GET` returns a version stamp; the authenticated `POST` actions are `ping`, `updateConfig`, `diagnose` (secret checks return pass/fail only, never values), `installTrigger`, and `sync`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Bot doesn't reply at all | Webhook not registered (re-run `setupWebhook` in the editor) or Gemini/Telegram key missing in Script Properties |
| Reply says *parked as Needs mapping* | A participant has no Splitwise Identity yet — set it in Notion → People; it pushes on the next sync |
| Expense stuck > 15 min | Check `/status`; verify the `pollSplitwise` trigger exists (⏰ page) |
| Web App returns a Google HTML error page | Loader couldn't fetch/eval the backend — check the execution log; the last-good fallback needs one prior successful fetch |
| Group missing from Notion Groups | Non-INR groups are excluded by design |

---

*IronBank was formerly SettleSmart. The old local-dashboard stack (FastAPI + SQLite + Google Sheet) is fully retired — this repository contains only the going-forward system.*
