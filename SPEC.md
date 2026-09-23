# CRM & Lead Ledger — MCP Server Spec

Status: **v0.1.0 built 2026-09-23.** Opening "CRM / Lead Ledger" on the Prometheus App Store
opportunity map (business operations). Chosen over Contract Vault, the Delegation Registry and
More Oracles because it needs no money to demo and composes directly with a shipped server:
Dispatch Scheduler.

## Why this exists

Dispatch Scheduler knows about a customer from the moment they book. Invoice Desk knows about
them from the moment they owe. Nothing on the store knows about them *before* that — the call
that came in Tuesday, the quote sent Thursday, the follow-up nobody made. That gap is where a
small service business loses most of its revenue, and it is the part an agent is best at:
remembering to call back.

## Shape

One principal owns one **book**. A book holds:

| Object | What it is | Mutability |
|---|---|---|
| **Contact** | A person or company: name, company, email, phone, address, source, tags, **stage** (`lead → qualified → customer`, or `lost` / `archived`) | Editable; never deleted (merged or erased instead) |
| **Activity** | One interaction: call, email, text, meeting, visit, note, inquiry, reply | **Append-only.** A wrong note is corrected by a new note |
| **Follow-up** | A dated next step on a contact | open → done / cancelled, with an outcome |
| **Deal** | A priced opportunity: `new → contacted → quoted → negotiating → won / lost` | Stage history recorded |
| **Inquiry** | A message *from another principal's agent* into a listed book | Sender can read status and replies |

## The agent-native part: inbound inquiries

`find_businesses` and `submit_inquiry` are open to any authenticated principal. A customer's
agent finds a listed business and files an inquiry ("spring snapped, door stuck half open, can
someone come Thursday?"). It lands in the business's book as a lead — or on the existing contact
for that principal — with an inbound activity and a place on the business's agenda.
`reply_to_inquiry` answers it; the sender's agent reads the reply with `my_inquiries`.

That is the machine-to-machine front door Dispatch Scheduler's `find_slots` is the back door of.

Spam limits (a sender cannot flood a book): at most **3 unanswered inquiries per sender per
book**, **10 inquiries per sender per rolling 24h** across all books, and a book stops accepting
new inquiries at **500 unanswered**.

## Decided in the build

1. **No money moves.** Deals carry a value quote only. `move_deal` to `won` returns ready-made
   argument blocks for Dispatch Scheduler `book` and Invoice Desk `create_invoice` — the same
   hand-off pattern Escrow uses for `submit_review`. No cross-canister calls.
2. **Plaintext, owner-scoped — not vetKey-encrypted.** A CRM is only useful if it can be
   searched server-side (`find_contacts`, duplicate detection, stale-lead detection), and all of
   that is impossible over ciphertext. Every record is readable only through its owner's key;
   ids from another book return "not found", never "belongs to someone else". The honest caveat,
   stated in the README: canister state is not end-to-end encrypted, so don't put anything in a
   note you would not put in a hosted CRM.
3. **Erasure exists** (`forget_contact`, confirm required). Unlike the Review Oracle, a CRM holds
   third parties' personal data, and they did not consent to permanence. Erasure scrubs name,
   email, phone, address, notes, activity and inquiry text, and follow-up task text; it keeps the
   *shape* (counts, dates, stages, deal values) so pipeline math stays true.
4. **Duplicates are refused, not silently created.** `add_contact` matches on normalized email,
   phone digits (last 10), and case-folded name+company. A match returns the existing ids; pass
   `allow_duplicate: true` to insist. `merge_contacts` folds one record into another — activities,
   follow-ups, deals and inquiries move; blank fields fill; tags union; the merged record becomes a
   tombstone pointing at the survivor.
5. **Won deal promotes the contact to `customer`; opening a deal on a lead moves it to `qualified`.** Losing a deal does not demote anyone.
6. **Time** follows Dispatch Scheduler: a fixed UTC offset per book, `YYYY-MM-DD HH:MM` local.
   Follow-up due dates also accept `YYYY-MM-DD` (09:00 local), `today`, `tomorrow`, `+N`.
7. **Stale lead** = stage `lead` or `qualified`, no touch in `stale_days` (default 14), and no open
   follow-up. Notes and system events do not count as a touch; calls, emails, texts, meetings,
   visits, inquiries and replies do.
8. **No timer.** Overdue and stale are computed at read time, so there is nothing to sweep.

## Tools (18)

| Tool | Who | Does |
|---|---|---|
| `setup_crm` | owner | Create/update the book: name, timezone, stale threshold, listing + intake note |
| `find_businesses` | any | Listed books taking inquiries |
| `submit_inquiry` | any | Send an inquiry into a listed book |
| `my_inquiries` | any | Inquiries you sent, with status and replies |
| `reply_to_inquiry` | owner | Answer an inquiry; logged as an outbound activity |
| `add_contact` | owner | Create or update a contact; duplicate-checked |
| `find_contacts` | owner | Search by text, stage, tag, source, staleness |
| `get_contact` | owner | Full record: timeline, deals, follow-ups, inquiries, hand-off blocks |
| `set_stage` | owner | Move a contact's stage (lost needs a reason) |
| `log_activity` | owner | Append an interaction; optionally schedule the next step in the same call |
| `schedule_follow_up` | owner | Dated next step on a contact |
| `complete_follow_up` | owner | Done or cancelled, with outcome; optionally chain the next one |
| `get_agenda` | owner | Overdue, due today, upcoming, unanswered inquiries, stale leads, deals past close |
| `add_deal` | owner | Create or update a priced opportunity |
| `move_deal` | owner | Stage change; won returns Dispatch + Invoice hand-offs |
| `get_pipeline` | owner | Stage totals, win rate, days-to-close, conversion by source |
| `merge_contacts` | owner | Fold a duplicate into a survivor |
| `forget_contact` | owner | Irreversible PII erasure |

## Deferred (v1.1+)

- Shared books (a teammate or assistant agent with read or write grants)
- Delivering follow-up nudges through Encrypted Mailbox or a Notifications bridge
- Cross-canister hand-off (actually calling Dispatch `book`) once the Delegation Registry exists
- Import from CSV
