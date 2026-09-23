# CRM & Lead Ledger

An MCP server for the [Prometheus Protocol](https://prometheusprotocol.org) app store: contacts, interaction history, follow-ups, and deals as canister state — plus an inquiry inbox any customer's agent can write to.

**Status:** v0.1.0, built and locally verified. Not yet on mainnet.

## What it does

- **The part before the booking.** Dispatch Scheduler knows a customer once they book; Invoice Desk once they owe. This is everything before that — the call Tuesday, the quote Thursday, the follow-up nobody made.
- **An inbox agents can write to.** List your book and any customer's agent can find you (`find_businesses`) and file an inquiry (`submit_inquiry`). It lands as a lead — or on the contact you already have for that principal — and goes on your agenda. Your reply reaches their agent through `my_inquiries`.
- **One place to start the day.** `get_agenda` returns overdue follow-ups, what's due today and this week, inquiries waiting on a reply, stale leads nobody is working, and deals past their expected close.
- **Nothing falls through.** A lead untouched for `stale_days` with nothing scheduled is flagged. `log_activity` and `complete_follow_up` can each schedule the next step in the same call, so the chain doesn't break.
- **Honest history.** The activity timeline is append-only — correct a note with a new note. Stage changes, deal moves, value changes, and merges are all recorded with a reason.
- **Duplicates refused, not silently created.** Matching email, phone (last 10 digits, any format), or name+company returns the existing contact. `merge_contacts` folds a duplicate in without losing a detail.
- **Hand-offs, not payments.** Winning a deal promotes the contact to customer and returns ready-made arguments for Dispatch Scheduler `book` and Invoice Desk `create_invoice`. No money moves here.
- **Erasure.** `forget_contact` scrubs a person's data for a deletion request while keeping dates, stages, and deal values, so your pipeline numbers stay true.

## Tools

| Tool | Who | Does |
|---|---|---|
| `setup_crm` | owner | Create/update the book: timezone, stale threshold, listing, intake note |
| `find_businesses` | any | Listed books taking inquiries |
| `submit_inquiry` | any | Send an inquiry into a listed book |
| `my_inquiries` | any | Inquiries you've sent, with status and replies |
| `reply_to_inquiry` | owner | Answer an inquiry; logged as an outbound reply |
| `add_contact` | owner | Create or update a contact; duplicate-checked |
| `find_contacts` | owner | Search by text, stage, tag, source, staleness |
| `get_contact` | owner | Full record: timeline, follow-ups, deals, inquiries, hand-offs |
| `set_stage` | owner | lead → qualified → customer, or lost (reason required) / archived |
| `log_activity` | owner | Call, email, text, meeting, visit, or note; optionally close a follow-up and schedule the next |
| `schedule_follow_up` | owner | Dated next step on a contact |
| `complete_follow_up` | owner | Done or cancelled with an outcome; optionally log it and chain the next |
| `get_agenda` | owner | Your day |
| `add_deal` | owner | Open or edit a priced opportunity (opening one qualifies a lead) |
| `move_deal` | owner | new → contacted → quoted → negotiating → won / lost; won returns hand-offs |
| `get_pipeline` | owner | Stage totals, win rate, days to close, conversion by source |
| `merge_contacts` | owner | Fold a duplicate into a survivor |
| `forget_contact` | owner | Irreversible personal-data erasure |

## Inquiry flow

```
customer's agent                       business's agent
----------------                       ----------------
find_businesses  {query}
submit_inquiry   {business, message}  ->  get_agenda        (inquiry waiting, new lead)
                                          reply_to_inquiry  {inquiry_id, message}
my_inquiries                          <-
                                          add_deal -> move_deal won -> handoff
                                          -> Dispatch Scheduler book / Invoice Desk create_invoice
```

Inbox limits: 3 unanswered inquiries per sender per book, 10 inquiries per sender per 24 hours, and a book stops accepting at 500 unanswered. Books are **private by default** — `listed=true` is a deliberate choice.

## Privacy

Every record is readable only through its owner's key, and another book's ids answer "not found" rather than confirming anything exists. Data is **not** end-to-end encrypted: a CRM has to be searchable server-side for duplicate detection, search, and stale-lead detection, which ciphertext rules out. Treat it like a hosted CRM — don't put anything in a note you wouldn't put there.

## Time

Follow-up times are in the book's local time, set once as `timezone_offset_minutes` — a **fixed** UTC offset (no DST database on-chain; shift it twice a year if you observe DST). Times go in and come out as `YYYY-MM-DD HH:MM`. A due date can also be `YYYY-MM-DD`, `today`, `tomorrow`, or `+3`, which all mean 09:00 local.

## Local development

```bash
mops install
dfx start --background
dfx deploy
dfx canister call crm_lead_ledger create_my_api_key '("my-key", vec {})'
python3 scripts/local-verify.py   # 74 end-to-end checks against the local replica
```

Auth follows the store pattern: mint a key with `create_my_api_key`, send it as `x-api-key`. Values are stored in cents; timestamps in nanoseconds.

## Deferred (v1.1+)

- Shared books: a teammate or assistant agent with read or write grants
- Follow-up nudges delivered through Encrypted Mailbox or a Notifications bridge
- Actually calling Dispatch `book` cross-canister, once the Delegation Registry exists
- CSV import
