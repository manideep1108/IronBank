# IronBank — Notion Dashboard Build Guide

Your expenses flow into Notion automatically from Telegram and Splitwise. This guide walks you through building the **views** — once — so your home page reads like a proper ledger and tells you exactly what needs your attention.

> **Why manual?** The Notion API can create databases and properties but **not views** — the view layer is the one thing you build by hand. Do it once; it keeps working forever.
>
> **No charts in this build.** Every "breakdown" below is a **grouped table** or **board** with a **column Sum** turned on — Notion totals each group for you. Wherever you'd expect a pie or bar chart, group a table instead.
>
> **Freshness:** data is up to ~15 minutes old (the sync interval). `Groups → Last Synced` shows the last sync; send `/sync` to the bot to refresh now, `/status` to see sync health.

## 0. The 60-second Notion mechanics primer

Everything below is a **linked view** of one of the four databases. If you haven't built one before:

1. On your dashboard page type `/linked` and choose **Linked view of database**, then pick the database (e.g. *Expenses*).
2. Use the view's **⋯ menu → Filter / Sort / Group** to apply the recipe.
3. For sums: hover just **below a number column's last row** and a `Calculate ▾` toggle appears — choose **Sum**. In grouped views each group gets its own sum.
4. **Properties** in the ⋯ menu controls which columns show.

## 1. Page skeleton

Create one page (e.g. **🏦 IronBank**) and add sections in this order — attention items first, reference material last:

1. ⚠️ **Needs Your Attention**
2. 💰 **Balances**
3. 📊 **Expenditure**
4. 🔧 **Splitwise Manager**
5. 🧩 **How to resolve things** (the cheatsheet from §6, pasted as text)
6. 🗄 **System** (the raw databases, in toggles)

## 2. ⚠️ Needs Your Attention — three linked views

**Expenses to map** — `Table` on **Expenses**
- Filter: `Settlement Status` **is** `Needs mapping`
- Sort: `Date` descending
- Show: Description · Splits Summary · Total Amount · Participants
- *Why:* recorded but couldn't push to Splitwise — usually a participant isn't set up. Fix the person (§6) and it clears automatically on the next sync.

**People to set up** — `Table` on **People**
- Filter: `Splitwise User ID` **is empty**
- Show: Name · Aliases · **Candidates** · Splitwise Identity
- *Why:* a person can't settle until they have an identity. The **Candidates** column carries poller-suggested matches — usually the right one is already listed; pick it in the `Splitwise Identity` dropdown right here.

**Pending sync actions** — `Table` on **Expenses**
- Filter: `Sync Action` **is not empty** *and* `Sync Action` **is not** `None`
- Show: Description · Sync Action · Sync Status
- *Why:* confirms a Delete/Re-push you requested is queued; rows clear once the sync carries them out. `Sync Status` explains anything that couldn't be done.

## 3. 💰 Balances

**Balances** — `Table` on **People**
- Filter: `Net Balance` **≠** 0  *(hides settled people)*
- Sort: `Net Balance` descending
- Show: Name · Net Balance · Net Balance By Group
- Calculate: **Sum** on `Net Balance`
- *Why:* positive = they owe you, negative = you owe them; the column Sum is your overall net position. `Net Balance By Group` shows per-group amounts (by group **name**) for when you actually settle — settle in the Splitwise app; payments flow back automatically.

**Owes you / You owe** *(optional)* — `Board` on **People**
- First add a formula property `Direction` to People:
  ```
  if(prop("Net Balance") > 0, "Owes you", if(prop("Net Balance") < 0, "You owe", "Settled"))
  ```
- Group by: `Direction` · Calculate: Sum of `Net Balance` per column
- *Why:* two tidy stacks so you see both sides at once.

> **Where are the settle-up payments?** Recorded payments deliberately do **not** appear as Expense rows — they only move `Net Balance`. If someone paid you back, look at Balances, not the ledger.

## 4. 📊 Expenditure

All grouped tables with **Sum on `Amount`**. `Amount` is **your share** (what *you* spent); `Total Amount` is the full bill — don't sum that one unless you want group turnover.

| View | Layout | Recipe |
|---|---|---|
| **This Month** | Table on Expenses | Filter: `Date` is within **This month** · Sort `Date` desc · Sum on `Amount` |
| **By Category** | Board (or grouped Table) on Expenses | Group by `Expense Type` · Sum on `Amount` per group — *this is the pie chart, without the pie* |
| **By Month** | Table on Expenses | Group by `Month` (auto-computed `YYYY-MM`, so years never merge) · sort groups desc · Sum on `Amount` |
| **By Year** | Table on Expenses | Group by `Year` · Sum on `Amount` |
| **By Person** | Table on Expenses | Filter: `Participants` **contains** *\<person\>* · Sum on `Amount` — your full shared history with one person. Duplicate per person you care about |
| **All Expenses** | Table on Expenses | No filter · Sort `Date` desc — the raw ledger, for search and audits |

`Month` and `Year` are formulas computed from `Date` — nothing to fill in.

## 5. 🔧 Splitwise Manager

**Groups** — `Table` on **Groups**
- Show: Name · `Allowed` · `Backfilled` · Last Synced · Sort: `Allowed` first, then Name
- *Why:* tick `Allowed` to onboard a group — the next sync pulls its full history once (`Backfilled` flips when done), then keeps it current. Untick to stop importing. Non-INR groups never appear (by design).

**Contacts** — `Table` on **Splitwise Users**
- Show: Name · Email · In Groups · Sort: Name ascending
- *Why:* your whole Splitwise address book, kept in sync automatically. You don't edit it — it's what the `Splitwise Identity` dropdown picks from.

## 6. 🧩 How to resolve things

**Set up a person (clears "Needs mapping" expenses)**
1. Open the person in **People**.
2. Check **Candidates** for suggested matches, then pick them in the `Splitwise Identity` dropdown — their Splitwise ID and display name fill in automatically on the next sync.
3. *Optional:* set a `Default Group` to route their expenses into a specific Splitwise group. **Leave it empty** and they settle as direct friend expenses.
4. Done — parked expenses with them push automatically on the next sync (`/sync` to hurry it).

**Merge a nickname or duplicate** (the bot created "Mang" but that's really Mangalik)
1. Open the **stray** row in People → set `Merge Into` to the real person.
2. The next sync saves the stray name as an alias, re-points every expense, archives the stray. That nickname resolves silently forever after.

**Answer an ambiguous name** ("Adi" → Aditya or Aditi?)
- The bot asks right in Telegram with buttons — tap the right person. The nickname is saved; it's never asked again. Nothing to do in Notion. (If the buttons expired: the expense **is** logged — fix via `Merge Into`, don't re-send.)

**Delete or re-push an expense**
- Fastest: tap **🗑️ Delete** on the bot's reply — removes it from Splitwise *and* Notion (and tells you if anything failed).
- From Notion: set `Sync Action` to `Delete` (removes everywhere) or `Re-push` (rebuilds the Splitwise side — the new expense is created *before* the old is removed, so nothing is lost if it fails). The next sync executes it and writes the outcome to `Sync Status`.

## 7. Settlement Status reference

| Status | Meaning | Act? |
|---|---|---|
| `Settled-via-Splitwise` | Pushed to Splitwise (group or direct friend expense); balances reflect it | No |
| `Needs mapping` | Recorded, but a participant isn't set up, so it couldn't push | Yes — set up the person (§6); clears automatically |
| `Notion-only` | In your ledger but never sent to Splitwise — a solo expense or historical data | No |
