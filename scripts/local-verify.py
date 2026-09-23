#!/usr/bin/env python3
"""Local end-to-end verification for CRM & Lead Ledger.

Deploys to the running local replica, mints keys for three principals — the
business, a customer's agent, and a stranger — and walks every tool through
the paths that matter: the inquiry inbox and its spam limits, duplicate
refusal, merging, follow-up chaining, stale detection, deal hand-offs,
pipeline math, isolation between books, erasure, and upgrade persistence.

Usage:  python3 scripts/local-verify.py      (needs dfx with a replica running)
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
os.environ["DFX_WARNING"] = "-mainnet_plaintext_identity"

passed = 0


def say(t):
    print(f"\n\033[1m{t}\033[0m")


def ok(t):
    global passed
    passed += 1
    print(f"  ok   {t}")


def check(cond, t, detail=None):
    if not cond:
        print(f"  FAIL {t}")
        if detail is not None:
            print(json.dumps(detail, indent=2)[:3000])
        sys.exit(1)
    ok(t)


def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


for ident in ("crm-customer", "crm-stranger"):
    subprocess.run(["dfx", "identity", "new", ident, "--storage-mode", "plaintext"], capture_output=True)

say("Deploying")
subprocess.run(["dfx", "deploy", "crm_lead_ledger", "--mode", "reinstall", "--yes"], check=True, capture_output=True)  # clean slate each run
CANISTER = sh("dfx", "canister", "id", "crm_lead_ledger")
CUSTOMER_P = sh("dfx", "identity", "get-principal", "--identity", "crm-customer")
OWNER_P = sh("dfx", "identity", "get-principal", "--identity", "default")


def mint(identity):
    out = sh("dfx", "canister", "call", "crm_lead_ledger", "create_my_api_key", '("verify", vec {})', "--identity", identity)
    return out.split('"')[1]


OWNER = mint("default")
CUSTOMER = mint("crm-customer")
STRANGER = mint("crm-stranger")
ok(f"canister {CANISTER}, three keys minted")


def call(key, tool, args=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args or {}}}).encode()
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if key:
        headers["x-api-key"] = key
    req = urllib.request.Request(f"http://127.0.0.1:4943/mcp?canisterId={CANISTER}", data=body, headers=headers)
    with urllib.request.urlopen(req) as r:
        res = json.load(r)
    if "result" not in res:
        return {"_error": True, "_text": json.dumps(res)}
    result = res["result"]
    text = result["content"][0]["text"] if result.get("content") else ""
    out = dict(result.get("structuredContent") or {})
    out["_error"] = bool(result.get("isError"))
    out["_text"] = text
    return out


def good(key, tool, args=None):
    r = call(key, tool, args)
    if r["_error"]:
        print(f"  FAIL {tool} errored: {r['_text']}")
        sys.exit(1)
    return r


def refused(key, tool, args, needle, t):
    r = call(key, tool, args)
    check(r["_error"] and needle.lower() in r["_text"].lower(), t, r)
    return r


# ---------------------------------------------------------------------------
say("1. Tool surface and auth")
listing = urllib.request.urlopen(urllib.request.Request(
    f"http://127.0.0.1:4943/mcp?canisterId={CANISTER}",
    data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}).encode(),
    headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "x-api-key": OWNER}))
tools = [t["name"] for t in json.load(listing)["result"]["tools"]]
check(len(tools) == 18, f"18 tools listed ({len(tools)})")
try:
    call(None, "get_agenda")
    check(False, "no key is refused with HTTP 401")
except urllib.error.HTTPError as e:
    check(e.code == 401, "no key is refused with HTTP 401")
refused(OWNER, "get_agenda", {}, "setup_crm", "tools before setup_crm say to run it")

# ---------------------------------------------------------------------------
say("2. A private book stays out of discovery until it lists")
good(OWNER, "setup_crm", {"name": "Legacy Garage Doors", "timezone_offset_minutes": -300})
r = good(CUSTOMER, "find_businesses", {"query": "garage"})
check(r["total_matches"] == 0, "unlisted book is not discoverable")
refused(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "Door is stuck halfway open."}, "not taking inquiries", "unlisted book refuses inquiries")
good(OWNER, "setup_crm", {"name": "Legacy Garage Doors", "listed": True, "service_area": "Hattiesburg & Purvis, MS",
                          "intake_note": "Door size, opener brand, and the address."})
r = good(CUSTOMER, "find_businesses", {"query": "hattiesburg"})
check(r["total_matches"] == 1 and r["businesses"][0]["business"] == OWNER_P, "listed book found by service area")
check(r["businesses"][0]["intake_note"].startswith("Door size"), "intake note is shown to the inquiring agent")

# ---------------------------------------------------------------------------
say("3. Inbox: an inquiry becomes a lead, with limits")
refused(OWNER, "submit_inquiry", {"business": OWNER_P, "message": "Testing my own inbox here."}, "own book", "cannot inquire into your own book")
r = good(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "subject": "Broken spring",
                                       "message": "Spring snapped, 16x7 door stuck half open, LiftMaster opener. 412 Oak St, Purvis.",
                                       "name": "Dana Whitfield", "contact_info": "dana@example.com"})
Q1 = r["inquiry_id"]
good(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "Also: can you quote a new opener while you are here?"})
good(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "And is Thursday morning possible?"})
refused(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "Fourth message before any reply."}, "unanswered", "4th unanswered inquiry to one book is refused")

r = good(OWNER, "get_agenda")
check(len(r["inquiries_waiting"]) == 3, "all 3 inquiries on the agenda", r)
DANA = r["inquiries_waiting"][0]["contact_id"]
check(all(q["contact_id"] == DANA for q in r["inquiries_waiting"]), "all three landed on ONE contact")
c = good(OWNER, "get_contact", {"contact_id": DANA})
check(c["name"] == "Dana Whitfield" and c["email"] == "dana@example.com" and c["source"] == "inquiry" and c["stage"] == "lead",
      "lead created with name, parsed email, source=inquiry", c)
check(c["agent_principal"] == CUSTOMER_P, "contact remembers the sender's principal")
check(c["last_touch"] is not None, "an inquiry counts as a touch")

# ---------------------------------------------------------------------------
say("4. Replies reach the sender; other books cannot see or answer")
refused(STRANGER, "reply_to_inquiry", {"inquiry_id": Q1, "message": "hi"}, "setup_crm", "stranger with no book cannot reply")
good(STRANGER, "setup_crm", {"name": "Someone Else"})
refused(STRANGER, "reply_to_inquiry", {"inquiry_id": Q1, "message": "hi"}, "no inquiry", "another book's inquiry reads as not found")
refused(STRANGER, "get_contact", {"contact_id": DANA}, "no contact", "another book's contact reads as not found")
good(OWNER, "reply_to_inquiry", {"inquiry_id": Q1, "message": "We can do Thursday 8am. Spring replacement is $285."})
r = good(CUSTOMER, "my_inquiries")
mine = {q["inquiry_id"]: q for q in r["inquiries"]}
check(mine[Q1]["status"] == "replied" and "Thursday 8am" in mine[Q1]["replies"][0]["text"], "sender reads the reply in my_inquiries", r)
good(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "Thursday 8am works, thank you!"})
ok("answering one inquiry frees a slot for the next")
r = good(OWNER, "get_contact", {"contact_id": DANA})
kinds = [a["kind"] for a in r["timeline"]]
check(kinds.count("inquiry") == 4 and kinds.count("reply") == 1, "timeline holds 4 inquiries + 1 reply", kinds)

# ---------------------------------------------------------------------------
say("5. Duplicates are refused; merge folds them together")
r = good(OWNER, "add_contact", {"name": "Marcus Bell", "phone": "(601) 555-0142", "address": "88 Pine Rd, Hattiesburg",
                                "source": "referral", "tags": ["Commercial", "warranty"]})
MARCUS = r["contact"]["contact_id"]
check(r["contact"]["tags"] == ["commercial", "warranty"], "tags lowercased")
r = refused(OWNER, "add_contact", {"name": "M. Bell", "phone": "+1 601.555.0142"}, "already have", "same phone in another format is caught")
check(r["duplicates"][0]["contact_id"] == MARCUS and r["duplicates"][0]["matched_on"] == "same phone number", "refusal names the existing id")
refused(OWNER, "add_contact", {"name": "marcus bell "}, "already have", "same name (case/space-insensitive) is caught")
refused(OWNER, "add_contact", {"name": "X", "email": "not-an-email"}, "email", "bad email rejected")
r = good(OWNER, "add_contact", {"name": "M. Bell", "phone": "+1 601.555.0142", "email": "mbell@bellbuilds.com",
                                "address": "Bell Builds yard, Hwy 98", "tags": "gate", "allow_duplicate": True})
MBELL = r["contact"]["contact_id"]
good(OWNER, "log_activity", {"contact_id": MBELL, "kind": "call", "summary": "Asked about a gate operator."})
r = good(OWNER, "merge_contacts", {"keep_id": MARCUS, "merge_id": MBELL})
c = good(OWNER, "get_contact", {"contact_id": MARCUS})
check(c["email"] == "mbell@bellbuilds.com", "blank email filled from the duplicate")
check(set(c["tags"]) == {"commercial", "warranty", "gate"}, "tags unioned", c["tags"])
check("Hwy 98" in (c["notes"] or ""), "differing address preserved in notes", c["notes"])
check(c["timeline_total"] == 1, "duplicate's timeline moved over")
r = good(OWNER, "get_contact", {"contact_id": MBELL})
check(r.get("merged_into") == MARCUS, "old id explains where it went")
refused(OWNER, "log_activity", {"contact_id": MBELL, "kind": "note", "summary": "x"}, "merged into", "tombstone cannot be written to")

# ---------------------------------------------------------------------------
say("6. Activities and follow-ups")
refused(OWNER, "log_activity", {"contact_id": MARCUS, "kind": "inquiry", "summary": "x"}, "not an activity kind", "inquiry kind is inbox-only")
refused(OWNER, "log_activity", {"contact_id": MARCUS, "kind": "call", "summary": "x", "at": "2099-01-01 09:00"}, "future", "future-dated activity refused")
refused(OWNER, "log_activity", {"contact_id": MARCUS, "kind": "call", "summary": "x", "next_follow_up": "tomorrow"}, "next_task", "next_follow_up without next_task refused")
r = good(OWNER, "log_activity", {"contact_id": MARCUS, "kind": "call", "summary": "Wants a quote on 3 commercial doors.",
                                 "next_follow_up": "tomorrow", "next_task": "Send the 3-door quote"})
F1 = r["next_follow_up"]["follow_up_id"]
check(r["next_follow_up"]["due"].endswith("09:00"), "a bare day means 09:00 local", r["next_follow_up"])
refused(OWNER, "schedule_follow_up", {"contact_id": MARCUS, "due": "2020-01-01", "task": "x"}, "past", "past due date refused")
refused(OWNER, "schedule_follow_up", {"contact_id": MARCUS, "due": "whenever", "task": "x"}, "not a time", "unparseable due refused")
r = good(OWNER, "get_agenda", {"days": 7})
check(any(f["follow_up_id"] == F1 for f in r["upcoming"]), "tomorrow's follow-up is on the upcoming list", r["upcoming"])
refused(OWNER, "complete_follow_up", {"follow_up_id": F1}, "outcome", "completing needs an outcome")
r = good(OWNER, "complete_follow_up", {"follow_up_id": F1, "outcome": "Quote emailed, $5,400 for three.", "log_as": "email",
                                      "next_follow_up": "+3", "next_task": "Check they got the quote"})
F2 = r["next_follow_up"]["follow_up_id"]
check(r["follow_up"]["status"] == "done", "follow-up closed as done")
c = good(OWNER, "get_contact", {"contact_id": MARCUS})
check(c["timeline"][0]["kind"] == "email" and "Quote emailed" in c["timeline"][0]["summary"], "log_as wrote the outcome to the timeline")
refused(OWNER, "complete_follow_up", {"follow_up_id": F1, "outcome": "again"}, "already done", "cannot complete twice")
r = good(OWNER, "log_activity", {"contact_id": MARCUS, "kind": "text", "summary": "Confirmed they got it.", "completes_follow_up_id": F2})
check(r["completed_follow_up"]["status"] == "done", "log_activity can close the follow-up it fulfilled")

# ---------------------------------------------------------------------------
say("7. Stale leads (backdated touches)")
good(OWNER, "setup_crm", {"name": "Legacy Garage Doors", "stale_days": 14})
r = good(OWNER, "add_contact", {"name": "Ray Ortiz", "source": "yard sign"})
RAY = r["contact"]["contact_id"]
check(r["contact"]["stale"] is False, "a brand-new lead is not stale")
good(OWNER, "log_activity", {"contact_id": RAY, "kind": "call", "summary": "Left a voicemail.", "at": "2026-01-05 10:00"})
r = good(OWNER, "get_agenda")
check(any(c["contact_id"] == RAY for c in r["stale_leads"]), "lead untouched since January is stale", r["stale_leads"])
r = good(OWNER, "find_contacts", {"stale_only": True})
check([c["contact_id"] for c in r["contacts"]] == [RAY], "find_contacts stale_only returns just Ray", r)
good(OWNER, "log_activity", {"contact_id": RAY, "kind": "note", "summary": "Thinking about him."})
r = good(OWNER, "find_contacts", {"stale_only": True})
check(r["total_matches"] == 1, "a note does not count as a touch")
good(OWNER, "schedule_follow_up", {"contact_id": RAY, "due": "+2", "task": "Try Ray again"})
r = good(OWNER, "find_contacts", {"stale_only": True})
check(r["total_matches"] == 0, "scheduling a follow-up takes him off the stale list")

# ---------------------------------------------------------------------------
say("8. Search")
r = good(OWNER, "find_contacts", {"query": "555-0142"})
check([c["contact_id"] for c in r["contacts"]] == [MARCUS], "search by phone digits", r)
r = good(OWNER, "find_contacts", {"tag": "gate"})
check(r["total_matches"] == 1, "filter by tag")
r = good(OWNER, "find_contacts", {"stage": "lead"})
check(r["total_matches"] == 3, "filter by stage (Dana, Marcus, Ray)", r)

# ---------------------------------------------------------------------------
say("9. Deals, stages, and the hand-off")
r = good(OWNER, "add_deal", {"contact_id": DANA, "title": "Spring replacement", "value_usd": 285, "expected_close": "+2"})
D1 = r["deal"]["deal_id"]
check("moved from lead to qualified" in r["_text"] or "qualified" in r["message"], "a deal qualifies the lead", r)
refused(OWNER, "add_deal", {"contact_id": DANA, "title": "x", "stage": "won"}, "move_deal", "cannot open a deal as won")
refused(OWNER, "move_deal", {"deal_id": D1, "stage": "lost"}, "reason", "lost needs a reason")
good(OWNER, "move_deal", {"deal_id": D1, "stage": "quoted"})
r = good(OWNER, "move_deal", {"deal_id": D1, "stage": "won"})
h = r["handoff"]
check(h["dispatch_scheduler_book"]["arguments"]["customer_name"] == "Dana Whitfield", "Dispatch hand-off carries the customer", h)
check(h["invoice_desk_create_invoice"]["arguments"]["amount_usd"] == 285 and h["invoice_desk_create_invoice"]["arguments"]["payer"] == CUSTOMER_P,
      "Invoice hand-off carries amount and the inquirer as payer", h)
c = good(OWNER, "get_contact", {"contact_id": DANA})
check(c["stage"] == "customer", "winning a deal makes the contact a customer")
r = good(OWNER, "add_deal", {"contact_id": MARCUS, "title": "3 commercial doors", "value_usd": 5400})
D2 = r["deal"]["deal_id"]
good(OWNER, "move_deal", {"deal_id": D2, "stage": "lost", "reason": "Went with a cheaper installer"})
r = good(OWNER, "add_deal", {"contact_id": RAY, "title": "Opener install", "value_usd": 449.99})
D3 = r["deal"]["deal_id"]
r = good(OWNER, "add_deal", {"deal_id": D3, "value_usd": 499})
check(any("$449.99 → $499.00" in e["event"] for e in r["deal"]["history"]), "value change is recorded in deal history", r["deal"])
refused(OWNER, "set_stage", {"contact_id": RAY, "stage": "lost"}, "reason", "contact lost needs a reason")

# ---------------------------------------------------------------------------
say("10. Pipeline math")
p = good(OWNER, "get_pipeline")
check(p["won"]["deals"] == 1 and p["won"]["value_usd"] == 285, "won: 1 deal, $285", p)
check(p["lost"]["deals"] == 1 and p["lost"]["value_usd"] == 5400, "lost: 1 deal, $5,400")
check(p["win_rate_pct"] == 50, "win rate 50%")
check(p["open_deals"] == 1 and p["open_value_usd"] == 499, "open: 1 deal, $499")
src = {s["source"]: s for s in p["conversion_by_source"]}
check(src["inquiry"]["customers"] == 1 and src["inquiry"]["conversion_pct"] == 100, "inquiry source converted 1 of 1", src)
check(p["contacts_by_stage"]["customer"] == 1 and p["contacts_by_stage"]["qualified"] == 2, "contacts by stage", p["contacts_by_stage"])

# ---------------------------------------------------------------------------
say("11. Erasure")
refused(OWNER, "forget_contact", {"contact_id": DANA}, "confirm", "erasure needs confirm=true")
good(OWNER, "forget_contact", {"contact_id": DANA, "confirm": True})
r = good(OWNER, "get_contact", {"contact_id": DANA})
check("erased" in r["message"] and "Dana" not in json.dumps(r), "erased contact shows nothing identifying", r)
r = good(CUSTOMER, "my_inquiries")
check(all(q["message"] == "[erased]" and q["status"] == "closed" for q in r["inquiries"]), "sender's copies are scrubbed and closed too", r)
r = good(OWNER, "find_contacts", {"query": "whitfield", "stage": "all"})
check(r["total_matches"] == 0, "erased contact is unsearchable")
p = good(OWNER, "get_pipeline")
check(p["won"]["value_usd"] == 285, "pipeline still counts the erased contact's won deal")
good(CUSTOMER, "submit_inquiry", {"business": OWNER_P, "message": "Hi again, new door question."})
r = good(OWNER, "get_agenda")
check(r["inquiries_waiting"][0]["contact_id"] != DANA, "a new inquiry after erasure starts a fresh contact")

# ---------------------------------------------------------------------------
say("12. Upgrade persistence")
before = good(OWNER, "get_pipeline")
subprocess.run(["dfx", "deploy", "crm_lead_ledger", "--upgrade-unchanged", "--yes"], check=True, capture_output=True)
after = good(OWNER, "get_pipeline")
strip = lambda d: {k: v for k, v in d.items() if not k.startswith("_")}
check(strip(before) == strip(after), "pipeline identical across an upgrade")
check(good(OWNER, "get_contact", {"contact_id": MARCUS})["timeline_total"] == 4, "timeline survives the upgrade")

print(f"\n\033[1mAll {passed} checks passed.\033[0m")
