import Map "mo:map/Map";
import { nhash; phash; thash } "mo:map/Map";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Nat32 "mo:base/Nat32";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Json "mo:json";
import HttpTypes "mo:http-types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import SrvTypes "mo:mcp-motoko-sdk/server/Types";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";

shared ({ caller = deployer }) persistent actor class McpServer() = self {

  // --- CRM DATA MODEL ---
  //
  // One principal owns one book. A book holds contacts (people or companies
  // moving lead -> qualified -> customer), an append-only activity timeline per
  // contact, dated follow-ups, and priced deals. Nothing here moves money: a
  // deal's value is a quote, and a won deal hands off to Dispatch Scheduler and
  // Invoice Desk as ready-made argument blocks.
  //
  // A listed book also has an inbox. Any authenticated principal can file an
  // inquiry into it; the inquiry lands as a lead (or on the existing contact
  // for that principal) and the sender reads replies with my_inquiries.
  //
  // Every owner-scoped lookup answers "not found" for another book's ids, so
  // ids never confirm that someone else's record exists.

  type Book = {
    owner : Principal;
    name : Text;
    description : ?Text;
    contact : ?Text;
    serviceArea : ?Text;
    tzOffsetMinutes : Int; // fixed UTC offset; no DST database on-chain
    staleDays : Nat; // a lead untouched this long, with nothing scheduled, is stale
    listed : Bool; // discoverable via find_businesses and open to inquiries
    intakeNote : ?Text; // what an inquiring agent should include
    createdAt : Int;
  };

  type Stage = { #lead; #qualified; #customer; #lost; #archived };

  type LogEvent = { at : Int; event : Text };

  type Contact = {
    id : Nat;
    owner : Principal;
    name : Text;
    company : ?Text;
    email : ?Text;
    phone : ?Text;
    address : ?Text;
    source : ?Text;
    tags : [Text];
    notes : ?Text;
    agent : ?Principal; // the principal behind inbound inquiries, if any
    stage : Stage;
    stageReason : ?Text;
    lastTouchAt : ?Int;
    mergedInto : ?Nat; // tombstone: this record was folded into another
    erasedAt : ?Int; // tombstone: personal data scrubbed
    events : [LogEvent];
    createdAt : Int;
    updatedAt : Int;
  };

  type ActivityKind = { #call; #email; #text; #meeting; #visit; #note; #inquiry; #reply };

  type Direction = { #inbound; #outbound; #internal };

  type Activity = {
    id : Nat;
    owner : Principal;
    contactId : Nat;
    dealId : ?Nat;
    kind : ActivityKind;
    direction : Direction;
    summary : Text;
    at : Int; // when it happened (may be backdated, never future)
    loggedAt : Int;
  };

  type FollowUpStatus = { #open; #done; #cancelled };

  type FollowUp = {
    id : Nat;
    owner : Principal;
    contactId : Nat;
    dealId : ?Nat;
    task : Text;
    dueAt : Int;
    status : FollowUpStatus;
    outcome : ?Text;
    closedAt : ?Int;
    createdAt : Int;
  };

  type DealStage = { #new; #contacted; #quoted; #negotiating; #won; #lost };

  type Deal = {
    id : Nat;
    owner : Principal;
    contactId : Nat;
    title : Text;
    valueCents : ?Nat; // quote only; settlement belongs to Invoice Desk
    stage : DealStage;
    expectedCloseDay : ?Int; // local days since epoch
    lostReason : ?Text;
    closedAt : ?Int;
    events : [LogEvent];
    createdAt : Int;
    stageChangedAt : Int;
  };

  type InquiryStatus = { #open; #replied; #closed };

  type Reply = { at : Int; text : Text };

  type Inquiry = {
    id : Nat;
    business : Principal;
    sender : Principal;
    contactId : Nat;
    subject : Text;
    message : Text;
    senderName : ?Text;
    replyTo : ?Text; // how the sender asked to be reached, as given
    status : InquiryStatus;
    replies : [Reply];
    erased : Bool;
    createdAt : Int;
  };

  // --- LIMITS ---

  transient let nanosPerMinute : Int = 60_000_000_000;
  transient let nanosPerHour : Int = 3_600_000_000_000;
  transient let nanosPerDay : Int = 86_400_000_000_000;
  transient let minutesPerDay : Int = 1_440;

  transient let maxNameChars : Nat = 120;
  transient let maxFieldChars : Nat = 300;
  transient let maxTextChars : Nat = 2_000;
  transient let maxTags : Nat = 12;
  transient let maxTagChars : Nat = 40;
  transient let maxContactsPerBook : Nat = 5_000;
  transient let maxDealsPerBook : Nat = 5_000;
  transient let maxActivitiesPerBook : Nat = 50_000;
  transient let maxActivitiesPerContact : Nat = 1_000;
  transient let maxFollowUpsPerBook : Nat = 20_000;
  transient let maxOpenFollowUpsPerContact : Nat = 20;
  transient let maxEvents : Nat = 40;
  transient let maxListResults : Nat = 50;
  transient let maxReplies : Nat = 20;

  // Inbox spam limits: an inquiring agent cannot flood a book.
  transient let maxOpenInquiriesPerSenderPerBook : Nat = 3;
  transient let maxInquiriesPerSenderPerDay : Nat = 10;
  transient let maxUnansweredPerBook : Nat = 500;

  transient let followUpDefaultMinute : Nat = 9 * 60; // a date with no time means 09:00 local
  transient let erasedText : Text = "[erased]";

  // --- STATE ---

  var nextContactId : Nat = 1;
  var nextActivityId : Nat = 1;
  var nextFollowUpId : Nat = 1;
  var nextDealId : Nat = 1;
  var nextInquiryId : Nat = 1;

  let books : Map.Map<Principal, Book> = Map.new();
  let contactsById : Map.Map<Nat, Contact> = Map.new();
  let activitiesById : Map.Map<Nat, Activity> = Map.new();
  let followUpsById : Map.Map<Nat, FollowUp> = Map.new();
  let dealsById : Map.Map<Nat, Deal> = Map.new();
  let inquiriesById : Map.Map<Nat, Inquiry> = Map.new();

  // Indexes, so no query ever walks another book's records.
  let contactIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();
  let dealIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();
  let followUpIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();
  let inquiryIdsByBusiness : Map.Map<Principal, [Nat]> = Map.new();
  let inquiryIdsBySender : Map.Map<Principal, [Nat]> = Map.new();
  let activityIdsByContact : Map.Map<Nat, [Nat]> = Map.new();
  let followUpIdsByContact : Map.Map<Nat, [Nat]> = Map.new();
  let dealIdsByContact : Map.Map<Nat, [Nat]> = Map.new();
  let inquiryIdsByContact : Map.Map<Nat, [Nat]> = Map.new();
  let activityCountByOwner : Map.Map<Principal, Nat> = Map.new();
  // "<book principal>#<sender principal>" -> the contact that sender's inquiries land on.
  let contactByAgent : Map.Map<Text, Nat> = Map.new();

  // --- MCP SERVER PLUMBING ---

  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  let appContext : McpTypes.AppContext = State.init([]);
  let authContext : AuthTypes.AuthContext = AuthState.initApiKey(deployer);

  Cleanup.startCleanupTimer<system>(appContext);
  AuthCleanup.startCleanupTimer<system>(authContext);

  // Prometheus usage beacon — reports anonymized usage to the tracker canister.
  transient let beaconContext : Beacon.BeaconContext = Beacon.init(
    Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai"),
    ?(15 * 60),
  );
  Beacon.startTimer<system>(beaconContext);

  // --- CALENDAR MATH ---
  //
  // Days are days-since-epoch; the civil <-> days conversion is Howard
  // Hinnant's algorithm, which relies on division truncating toward zero
  // exactly as Motoko's Int division does.

  func floorDiv(a : Int, b : Int) : Int {
    let q = a / b;
    if (a % b != 0 and ((a < 0) != (b < 0))) q - 1 else q;
  };

  func floorMod(a : Int, b : Int) : Int { a - floorDiv(a, b) * b };

  func daysFromCivil(y0 : Int, m : Int, d : Int) : Int {
    let y = if (m <= 2) y0 - 1 else y0;
    let era = (if (y >= 0) y else y - 399) / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = floorMod(m + 9, 12); // March = 0
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468;
  };

  func civilFromDays(z0 : Int) : (Int, Int, Int) {
    let z = z0 + 719468;
    let era = (if (z >= 0) z else z - 146096) / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    (if (m <= 2) y + 1 else y, m, d);
  };

  /// 0 = Sunday. 1970-01-01 (day 0) was a Thursday.
  func dayOfWeek(days : Int) : Nat {
    Int.abs(floorMod(days + 4, 7));
  };

  transient let dayNames : [Text] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

  /// Absolute ns -> (local day, minute of local day) for a given UTC offset.
  func toLocal(at : Int, tzOffsetMinutes : Int) : (Int, Int) {
    let localMinutes = floorDiv(at, nanosPerMinute) + tzOffsetMinutes;
    let day = floorDiv(localMinutes, minutesPerDay);
    (day, localMinutes - day * minutesPerDay);
  };

  /// (local day, minute of local day) -> absolute ns.
  func fromLocal(day : Int, minute : Int, tzOffsetMinutes : Int) : Int {
    (day * minutesPerDay + minute - tzOffsetMinutes) * nanosPerMinute;
  };

  func pad2(n : Int) : Text {
    let a = Int.abs(n);
    if (a < 10) "0" # Nat.toText(a) else Nat.toText(a);
  };

  func fmtDate(days : Int) : Text {
    let (y, m, d) = civilFromDays(days);
    Int.toText(y) # "-" # pad2(m) # "-" # pad2(d);
  };

  func fmtClock(minute : Int) : Text {
    pad2(floorDiv(minute, 60)) # ":" # pad2(floorMod(minute, 60));
  };

  /// "Fri 2026-08-21 14:30" in the business's local time.
  func fmtLocal(at : Int, tzOffsetMinutes : Int) : Text {
    let (day, minute) = toLocal(at, tzOffsetMinutes);
    dayNames[dayOfWeek(day)] # " " # fmtDate(day) # " " # fmtClock(minute);
  };

  func fmtDuration(ns : Int) : Text {
    if (ns < nanosPerMinute) return "moments";
    if (ns < nanosPerHour) {
      let m = ns / nanosPerMinute;
      return Int.toText(m) # (if (m == 1) " minute" else " minutes");
    };
    if (ns < nanosPerDay) {
      let h = ns / nanosPerHour;
      return Int.toText(h) # (if (h == 1) " hour" else " hours");
    };
    let d = ns / nanosPerDay;
    Int.toText(d) # (if (d == 1) " day" else " days");
  };

  func usdText(cents : Nat) : Text {
    "$" # Nat.toText(cents / 100) # "." # pad2(cents % 100);
  };

  // --- TEXT PARSING ---

  func digitsToNat(t : Text) : ?Nat {
    if (t.size() == 0) return null;
    var acc : Nat = 0;
    for (c in t.chars()) {
      if (not Char.isDigit(c)) return null;
      acc := acc * 10 + Nat32.toNat(Char.toNat32(c) - 48);
    };
    ?acc;
  };

  func lower(t : Text) : Text {
    Text.map(
      t,
      func(c : Char) : Char {
        let n = Char.toNat32(c);
        if (n >= 65 and n <= 90) Char.fromNat32(n + 32) else c;
      },
    );
  };

  func splitParts(t : Text, sep : Char) : [Text] {
    Buffer.toArray(
      do {
        let out = Buffer.Buffer<Text>(4);
        for (piece in Text.split(t, #char sep)) out.add(piece);
        out;
      }
    );
  };

  /// "YYYY-MM-DD" -> days since epoch.
  func parseDate(t : Text) : ?Int {
    let parts = splitParts(Text.trim(t, #char ' '), '-');
    if (parts.size() != 3) return null;
    let ?y = digitsToNat(parts[0]) else return null;
    let ?m = digitsToNat(parts[1]) else return null;
    let ?d = digitsToNat(parts[2]) else return null;
    if (y < 2020 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31) return null;
    let days = daysFromCivil(y, m, d);
    // Reject impossible dates (Feb 30) by round-tripping.
    let (ry, rm, rd) = civilFromDays(days);
    if (ry != y or rm != m or rd != d) return null;
    ?days;
  };

  /// "HH:MM" (24-hour) -> minutes from midnight.
  func parseClock(t : Text) : ?Nat {
    let parts = splitParts(Text.trim(t, #char ' '), ':');
    if (parts.size() != 2) return null;
    let ?h = digitsToNat(parts[0]) else return null;
    let ?m = digitsToNat(parts[1]) else return null;
    if (h > 23 or m > 59) return null;
    ?(h * 60 + m);
  };

  /// "YYYY-MM-DD HH:MM" or "YYYY-MM-DDTHH:MM" in business-local time -> ns.
  func parseLocalStamp(t : Text, tzOffsetMinutes : Int) : ?Int {
    let cleaned = Text.trim(Text.map(t, func(c : Char) : Char { if (c == 'T') ' ' else c }), #char ' ');
    let parts = splitParts(cleaned, ' ');
    if (parts.size() < 2) return null;
    let ?day = parseDate(parts[0]) else return null;
    // Tolerate a trailing ":SS" from ISO-ish input.
    let timePieces = splitParts(parts[1], ':');
    if (timePieces.size() < 2) return null;
    let ?minute = parseClock(timePieces[0] # ":" # timePieces[1]) else return null;
    ?fromLocal(day, minute, tzOffsetMinutes);
  };

  /// A date argument: "today", "tomorrow", "YYYY-MM-DD", or +N days.
  func parseDayArg(t : Text, todayLocal : Int) : ?Int {
    let v = lower(Text.trim(t, #char ' '));
    if (v == "today" or v == "now") return ?todayLocal;
    if (v == "tomorrow") return ?(todayLocal + 1);
    switch (parseDate(v)) {
      case (?d) ?d;
      case (null) {
        if (Text.startsWith(v, #char '+')) {
          switch (digitsToNat(Text.trimStart(v, #char '+'))) {
            case (?n) ?(todayLocal + n);
            case (null) null;
          };
        } else null;
      };
    };
  };

  // --- GENERIC HELPERS ---

  func callerPrincipal(auth : ?AuthTypes.AuthInfo) : ?Principal {
    switch (auth) {
      case (?info) ?info.principal;
      case (null) null;
    };
  };

  func optText(args : McpTypes.JsonValue, field : Text) : ?Text {
    switch (Result.toOption(Json.getAsText(args, field))) {
      case (?t) { let v = Text.trim(t, #char ' '); if (v == "") null else ?v };
      case (null) null;
    };
  };

  func optNat(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (Result.toOption(Json.getAsNat(args, field))) {
      case (?n) ?n;
      case (null) {
        switch (Result.toOption(Json.getAsFloat(args, field))) {
          case (?f) { if (f < 0.0) null else ?Int.abs(Float.toInt(f)) };
          case (null) {
            switch (optText(args, field)) {
              case (?t) digitsToNat(t);
              case (null) null;
            };
          };
        };
      };
    };
  };

  func optInt(args : McpTypes.JsonValue, field : Text) : ?Int {
    switch (Result.toOption(Json.getAsInt(args, field))) {
      case (?n) ?n;
      case (null) {
        switch (Result.toOption(Json.getAsFloat(args, field))) {
          case (?f) ?Float.toInt(f);
          case (null) {
            switch (optText(args, field)) {
              case (?t) {
                if (Text.startsWith(t, #char '-')) {
                  switch (digitsToNat(Text.trimStart(t, #char '-'))) {
                    case (?n) ?(-n);
                    case (null) null;
                  };
                } else {
                  switch (digitsToNat(Text.trimStart(t, #char '+'))) {
                    case (?n) ?n;
                    case (null) null;
                  };
                };
              };
              case (null) null;
            };
          };
        };
      };
    };
  };

  func optBool(args : McpTypes.JsonValue, field : Text) : ?Bool {
    switch (Result.toOption(Json.getAsBool(args, field))) {
      case (?b) ?b;
      case (null) {
        switch (optText(args, field)) {
          case (?t) {
            switch (lower(t)) {
              case ("true") ?true;
              case ("yes") ?true;
              case ("false") ?false;
              case ("no") ?false;
              case (_) null;
            };
          };
          case (null) null;
        };
      };
    };
  };

  /// Money in, cents out: 85 -> 8500, 85.5 -> 8550.
  func optPriceCents(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (Result.toOption(Json.getAsFloat(args, field))) {
      case (?f) { if (f < 0.0) null else ?Int.abs(Float.toInt(f * 100.0 + 0.5)) };
      case (null) {
        switch (optNat(args, field)) {
          case (?n) ?(n * 100);
          case (null) null;
        };
      };
    };
  };

  func errorResult(msg : Text) : McpTypes.CallToolResult {
    { content = [#text({ text = msg })]; isError = true; structuredContent = null };
  };

  func okResult(payload : Json.Json) : McpTypes.CallToolResult {
    {
      content = [#text({ text = Json.stringify(payload, null) })];
      isError = false;
      structuredContent = ?payload;
    };
  };

  func optJsonText(t : ?Text) : Json.Json {
    switch (t) { case (?v) Json.str(v); case (null) Json.nullable() };
  };

  func optJsonNat(n : ?Nat) : Json.Json {
    switch (n) { case (?v) Json.int(v); case (null) Json.nullable() };
  };

  func requireLen(value : Text, field : Text, min : Nat, max : Nat) : ?Text {
    let n = value.size();
    if (n < min) return ?("'" # field # "' must be at least " # Nat.toText(min) # " characters.");
    if (n > max) return ?("'" # field # "' must be at most " # Nat.toText(max) # " characters.");
    null;
  };

  // Charset/shape pre-check so obviously malformed principal text gets a clean
  // error; Principal.fromText still traps on a bad checksum, which surfaces as
  // a rejected call rather than a tool error — acceptable for copy-paste slips.
  func parsePrincipal(t : Text) : ?Principal {
    let trimmed = Text.trim(t, #char ' ');
    let n = trimmed.size();
    if (n < 5 or n > 63) return null;
    for (c in trimmed.chars()) {
      let ok = (Char.isLowercase(c) and Char.isAlphabetic(c)) or Char.isDigit(c) or c == '-';
      if (not ok) return null;
    };
    let p = Principal.fromText(trimmed);
    if (Principal.isAnonymous(p)) return null;
    ?p;
  };

  func shortPrincipal(p : Principal) : Text {
    let t = Principal.toText(p);
    let parts = splitParts(t, '-');
    if (parts.size() == 0) t else parts[0];
  };

  func appendCapped(ids : [Nat], id : Nat) : [Nat] { Array.append(ids, [id]) };

  func idsOf(index : Map.Map<Principal, [Nat]>, owner : Principal) : [Nat] {
    switch (Map.get(index, phash, owner)) { case (?ids) ids; case (null) [] };
  };

  func indexAdd(index : Map.Map<Principal, [Nat]>, owner : Principal, id : Nat) {
    Map.set(index, phash, owner, appendCapped(idsOf(index, owner), id));
  };


  func idsOfN(index : Map.Map<Nat, [Nat]>, key : Nat) : [Nat] {
    switch (Map.get(index, nhash, key)) { case (?ids) ids; case (null) [] };
  };

  func indexAddN(index : Map.Map<Nat, [Nat]>, key : Nat, id : Nat) {
    Map.set(index, nhash, key, appendCapped(idsOfN(index, key), id));
  };

  func pushEvent(events : [LogEvent], event : Text, at : Int) : [LogEvent] {
    let all = Array.append(events, [{ at = at; event = event }]);
    if (all.size() <= maxEvents) all else Array.subArray(all, all.size() - maxEvents, maxEvents);
  };

  func clip(t : Text, n : Nat) : Text {
    if (t.size() <= n) return t;
    let cs = Iter.toArray(t.chars());
    Text.fromIter(Array.subArray(cs, 0, n).vals()) # "…";
  };

  func contains(hay : Text, needle : Text) : Bool {
    Text.contains(lower(hay), #text needle);
  };

  func optContains(hay : ?Text, needle : Text) : Bool {
    switch (hay) { case (?h) contains(h, needle); case (null) false };
  };

  func usdFloat(cents : Nat) : Json.Json {
    Json.float(Float.fromInt(cents) / 100.0);
  };

  func pct(part : Nat, whole : Nat) : Json.Json {
    if (whole == 0) Json.nullable() else Json.int((part * 100 + whole / 2) / whole);
  };

  // --- NORMALIZATION (duplicate detection) ---

  func normEmail(t : Text) : Text { lower(Text.trim(t, #char ' ')) };

  func looksLikeEmail(t : Text) : Bool {
    let parts = splitParts(Text.trim(t, #char ' '), '@');
    parts.size() == 2 and parts[0].size() > 0 and Text.contains(parts[1], #char '.') and not Text.contains(t, #char ' ');
  };

  func phoneDigits(t : Text) : Text {
    var out = "";
    for (c in t.chars()) { if (Char.isDigit(c)) out #= Char.toText(c) };
    out;
  };

  /// Last ten digits, so "+1 (601) 555-0142" and "601.555.0142" match.
  func phoneKey(t : Text) : ?Text {
    let d = phoneDigits(t);
    if (d.size() < 7) return null;
    if (d.size() <= 10) return ?d;
    let cs = Iter.toArray(d.chars());
    ?Text.fromIter(Array.subArray(cs, cs.size() - 10, 10).vals());
  };

  func nameKey(name : Text, company : ?Text) : Text {
    let co = switch (company) { case (?c) lower(Text.trim(c, #char ' ')); case (null) "" };
    lower(Text.trim(name, #char ' ')) # "|" # co;
  };

  /// An array of strings, or one comma-separated string. Null when absent.
  func readTextList(args : McpTypes.JsonValue, field : Text) : ?[Text] {
    let raw : [Text] = switch (Result.toOption(Json.getAsArray(args, field))) {
      case (?items) {
        let out = Buffer.Buffer<Text>(items.size());
        for (item in items.vals()) {
          switch (item) { case (#string(s)) out.add(s); case (_) {} };
        };
        Buffer.toArray(out);
      };
      case (null) {
        switch (optText(args, field)) {
          case (?t) splitParts(t, ',');
          case (null) return null;
        };
      };
    };
    let out = Buffer.Buffer<Text>(raw.size());
    for (r in raw.vals()) {
      let v = Text.trim(r, #char ' ');
      if (v != "") out.add(v);
    };
    ?Buffer.toArray(out);
  };

  func normalizeTags(raw : [Text]) : Result.Result<[Text], Text> {
    let out = Buffer.Buffer<Text>(raw.size());
    for (t in raw.vals()) {
      let v = lower(t);
      if (v.size() > maxTagChars) return #err("Tag '" # clip(t, 20) # "' is longer than " # Nat.toText(maxTagChars) # " characters.");
      if (not Buffer.contains<Text>(out, v, Text.equal)) out.add(v);
    };
    if (out.size() > maxTags) return #err("At most " # Nat.toText(maxTags) # " tags per contact.");
    #ok(Buffer.toArray(out));
  };

  func hasField(list : [Text], name : Text) : Bool {
    for (f in list.vals()) { if (lower(f) == name) return true };
    false;
  };

  // --- ENUM TEXT ---

  func stageText(s : Stage) : Text {
    switch (s) {
      case (#lead) "lead";
      case (#qualified) "qualified";
      case (#customer) "customer";
      case (#lost) "lost";
      case (#archived) "archived";
    };
  };

  func parseStage(t : Text) : ?Stage {
    switch (lower(t)) {
      case ("lead") ?#lead;
      case ("qualified") ?#qualified;
      case ("customer") ?#customer;
      case ("lost") ?#lost;
      case ("archived") ?#archived;
      case (_) null;
    };
  };

  /// How far along a contact is; merge keeps the further of the two.
  func stageRank(s : Stage) : Nat {
    switch (s) {
      case (#archived) 0;
      case (#lost) 1;
      case (#lead) 2;
      case (#qualified) 3;
      case (#customer) 4;
    };
  };

  func isOpenStage(s : Stage) : Bool { s == #lead or s == #qualified };

  func dealStageText(s : DealStage) : Text {
    switch (s) {
      case (#new) "new";
      case (#contacted) "contacted";
      case (#quoted) "quoted";
      case (#negotiating) "negotiating";
      case (#won) "won";
      case (#lost) "lost";
    };
  };

  func parseDealStage(t : Text) : ?DealStage {
    switch (lower(t)) {
      case ("new") ?#new;
      case ("contacted") ?#contacted;
      case ("quoted") ?#quoted;
      case ("negotiating") ?#negotiating;
      case ("won") ?#won;
      case ("lost") ?#lost;
      case (_) null;
    };
  };

  func isClosedDeal(s : DealStage) : Bool { s == #won or s == #lost };

  transient let openDealStages : [DealStage] = [#new, #contacted, #quoted, #negotiating];

  func kindText(k : ActivityKind) : Text {
    switch (k) {
      case (#call) "call";
      case (#email) "email";
      case (#text) "text";
      case (#meeting) "meeting";
      case (#visit) "visit";
      case (#note) "note";
      case (#inquiry) "inquiry";
      case (#reply) "reply";
    };
  };

  /// inquiry and reply are written by the inbox tools, never logged by hand.
  func parseKind(t : Text) : ?ActivityKind {
    switch (lower(t)) {
      case ("call") ?#call;
      case ("email") ?#email;
      case ("text") ?#text;
      case ("sms") ?#text;
      case ("meeting") ?#meeting;
      case ("visit") ?#visit;
      case ("note") ?#note;
      case (_) null;
    };
  };

  /// A note is bookkeeping, not contact with the customer.
  func isTouch(k : ActivityKind) : Bool { k != #note };

  func directionText(d : Direction) : Text {
    switch (d) {
      case (#inbound) "inbound";
      case (#outbound) "outbound";
      case (#internal) "internal";
    };
  };

  func parseDirection(t : Text) : ?Direction {
    switch (lower(t)) {
      case ("inbound") ?#inbound;
      case ("in") ?#inbound;
      case ("outbound") ?#outbound;
      case ("out") ?#outbound;
      case ("internal") ?#internal;
      case (_) null;
    };
  };

  func followStatusText(s : FollowUpStatus) : Text {
    switch (s) { case (#open) "open"; case (#done) "done"; case (#cancelled) "cancelled" };
  };

  func inquiryStatusText(s : InquiryStatus) : Text {
    switch (s) { case (#open) "awaiting reply"; case (#replied) "replied"; case (#closed) "closed" };
  };

  // --- DOMAIN LOOKUPS ---

  func getBook(owner : Principal) : ?Book { Map.get(books, phash, owner) };
  func getContact(id : Nat) : ?Contact { Map.get(contactsById, nhash, id) };
  func getActivity(id : Nat) : ?Activity { Map.get(activitiesById, nhash, id) };
  func getFollowUp(id : Nat) : ?FollowUp { Map.get(followUpsById, nhash, id) };
  func getDeal(id : Nat) : ?Deal { Map.get(dealsById, nhash, id) };
  func getInquiry(id : Nat) : ?Inquiry { Map.get(inquiriesById, nhash, id) };

  func putContact(c : Contact) { Map.set(contactsById, nhash, c.id, c) };
  func putDeal(d : Deal) { Map.set(dealsById, nhash, d.id, d) };
  func putFollowUp(f : FollowUp) { Map.set(followUpsById, nhash, f.id, f) };
  func putInquiry(q : Inquiry) { Map.set(inquiriesById, nhash, q.id, q) };

  func isLive(c : Contact) : Bool { c.mergedInto == null and c.erasedAt == null };

  func bookContacts(owner : Principal) : [Contact] {
    let out = Buffer.Buffer<Contact>(16);
    for (id in idsOf(contactIdsByOwner, owner).vals()) {
      switch (getContact(id)) { case (?c) { if (isLive(c)) out.add(c) }; case (null) {} };
    };
    Buffer.toArray(out);
  };

  func bookDeals(owner : Principal) : [Deal] {
    let out = Buffer.Buffer<Deal>(16);
    for (id in idsOf(dealIdsByOwner, owner).vals()) {
      switch (getDeal(id)) { case (?d) out.add(d); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func contactActivities(cid : Nat) : [Activity] {
    let out = Buffer.Buffer<Activity>(16);
    for (id in idsOfN(activityIdsByContact, cid).vals()) {
      switch (getActivity(id)) { case (?a) out.add(a); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func contactFollowUps(cid : Nat) : [FollowUp] {
    let out = Buffer.Buffer<FollowUp>(8);
    for (id in idsOfN(followUpIdsByContact, cid).vals()) {
      switch (getFollowUp(id)) { case (?f) out.add(f); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func contactDeals(cid : Nat) : [Deal] {
    let out = Buffer.Buffer<Deal>(4);
    for (id in idsOfN(dealIdsByContact, cid).vals()) {
      switch (getDeal(id)) { case (?d) out.add(d); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func contactInquiries(cid : Nat) : [Inquiry] {
    let out = Buffer.Buffer<Inquiry>(4);
    for (id in idsOfN(inquiryIdsByContact, cid).vals()) {
      switch (getInquiry(id)) { case (?q) out.add(q); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func openFollowUpCount(cid : Nat) : Nat {
    var n = 0;
    for (f in contactFollowUps(cid).vals()) { if (f.status == #open) n += 1 };
    n;
  };

  /// Follow merge tombstones to the surviving record. Null if erased or gone.
  func resolveLive(id : Nat) : ?Contact {
    var cur = id;
    var hops = 0;
    while (hops < 16) {
      let ?c = getContact(cur) else return null;
      if (c.erasedAt != null) return null;
      switch (c.mergedInto) {
        case (?next) { cur := next; hops += 1 };
        case (null) return ?c;
      };
    };
    null;
  };

  func isStale(c : Contact, book : Book, now : Int) : Bool {
    if (not isOpenStage(c.stage)) return false;
    let since = switch (c.lastTouchAt) { case (?t) t; case (null) c.createdAt };
    if (now - since < book.staleDays * nanosPerDay) return false;
    openFollowUpCount(c.id) == 0;
  };

  /// Record an activity and move the contact's last-touch mark. The caller has
  /// already checked caps; the contact passed in is the live record.
  func recordActivity(
    owner : Principal,
    c : Contact,
    dealId : ?Nat,
    kind : ActivityKind,
    direction : Direction,
    summary : Text,
    at : Int,
    now : Int,
  ) : (Activity, Contact) {
    let a : Activity = {
      id = nextActivityId;
      owner = owner;
      contactId = c.id;
      dealId = dealId;
      kind = kind;
      direction = direction;
      summary = summary;
      at = at;
      loggedAt = now;
    };
    nextActivityId += 1;
    Map.set(activitiesById, nhash, a.id, a);
    indexAddN(activityIdsByContact, c.id, a.id);
    let count = switch (Map.get(activityCountByOwner, phash, owner)) { case (?n) n; case (null) 0 };
    Map.set(activityCountByOwner, phash, owner, count + 1);

    let touched = if (isTouch(kind)) {
      switch (c.lastTouchAt) {
        case (?t) { if (at > t) ?at else ?t };
        case (null) ?at;
      };
    } else c.lastTouchAt;
    let updated = { c with lastTouchAt = touched; updatedAt = now };
    putContact(updated);
    (a, updated);
  };

  func activityCapProblem(owner : Principal, cid : Nat) : ?Text {
    let count = switch (Map.get(activityCountByOwner, phash, owner)) { case (?n) n; case (null) 0 };
    if (count >= maxActivitiesPerBook) return ?("This book has reached " # Nat.toText(maxActivitiesPerBook) # " activities.");
    if (idsOfN(activityIdsByContact, cid).size() >= maxActivitiesPerContact) {
      return ?("Contact " # Nat.toText(cid) # " has reached " # Nat.toText(maxActivitiesPerContact) # " activities.");
    };
    null;
  };

  func insertFollowUp(owner : Principal, cid : Nat, dealId : ?Nat, task : Text, dueAt : Int, now : Int) : FollowUp {
    let f : FollowUp = {
      id = nextFollowUpId;
      owner = owner;
      contactId = cid;
      dealId = dealId;
      task = task;
      dueAt = dueAt;
      status = #open;
      outcome = null;
      closedAt = null;
      createdAt = now;
    };
    nextFollowUpId += 1;
    putFollowUp(f);
    indexAdd(followUpIdsByOwner, owner, f.id);
    indexAddN(followUpIdsByContact, cid, f.id);
    f;
  };

  func followUpCapProblem(owner : Principal, cid : Nat) : ?Text {
    if (idsOf(followUpIdsByOwner, owner).size() >= maxFollowUpsPerBook) {
      return ?("This book has reached " # Nat.toText(maxFollowUpsPerBook) # " follow-ups.");
    };
    if (openFollowUpCount(cid) >= maxOpenFollowUpsPerContact) {
      return ?("Contact " # Nat.toText(cid) # " already has " # Nat.toText(maxOpenFollowUpsPerContact) # " open follow-ups. Complete or cancel some first.");
    };
    null;
  };

  /// A follow-up due argument: "YYYY-MM-DD HH:MM" local, or a day
  /// ("YYYY-MM-DD", "today", "tomorrow", "+3") which means 09:00 local.
  func parseDue(t : Text, tz : Int, now : Int) : ?Int {
    switch (parseLocalStamp(t, tz)) {
      case (?at) ?at;
      case (null) {
        let (today, _) = toLocal(now, tz);
        switch (parseDayArg(t, today)) {
          case (?day) ?fromLocal(day, followUpDefaultMinute, tz);
          case (null) null;
        };
      };
    };
  };

  func fmtAgo(now : Int, at : Int) : Text {
    if (at > now) "in " # fmtDuration(at - now) else fmtDuration(now - at) # " ago";
  };

  // --- JSON VIEWS ---

  func tagsJson(tags : [Text]) : Json.Json { Json.arr(Array.map<Text, Json.Json>(tags, Json.str)) };

  func bookJson(b : Book, includePrivate : Bool) : Json.Json {
    let base = [
      ("business", Json.str(Principal.toText(b.owner))),
      ("name", Json.str(b.name)),
      ("description", optJsonText(b.description)),
      ("contact", optJsonText(b.contact)),
      ("service_area", optJsonText(b.serviceArea)),
      ("intake_note", optJsonText(b.intakeNote)),
    ];
    if (not includePrivate) return Json.obj(base);
    Json.obj(Array.append(base, [
      ("listed", Json.bool(b.listed)),
      ("timezone_offset_minutes", Json.int(b.tzOffsetMinutes)),
      ("stale_days", Json.int(b.staleDays)),
    ]));
  };

  func touchJson(c : Contact, tz : Int, now : Int) : (Json.Json, Json.Json) {
    switch (c.lastTouchAt) {
      case (?t) (Json.str(fmtLocal(t, tz)), Json.str(fmtAgo(now, t)));
      case (null) (Json.nullable(), Json.str("never"));
    };
  };

  func contactSummaryJson(c : Contact, book : Book, now : Int) : Json.Json {
    let (touch, ago) = touchJson(c, book.tzOffsetMinutes, now);
    let deals = contactDeals(c.id);
    var openDeals = 0;
    var openValue = 0;
    for (d in deals.vals()) {
      if (not isClosedDeal(d.stage)) {
        openDeals += 1;
        switch (d.valueCents) { case (?v) openValue += v; case (null) {} };
      };
    };
    Json.obj([
      ("contact_id", Json.int(c.id)),
      ("name", Json.str(c.name)),
      ("company", optJsonText(c.company)),
      ("stage", Json.str(stageText(c.stage))),
      ("email", optJsonText(c.email)),
      ("phone", optJsonText(c.phone)),
      ("source", optJsonText(c.source)),
      ("tags", tagsJson(c.tags)),
      ("last_touch", touch),
      ("last_touch_ago", ago),
      ("open_follow_ups", Json.int(openFollowUpCount(c.id))),
      ("open_deals", Json.int(openDeals)),
      ("open_deal_value_usd", usdFloat(openValue)),
      ("stale", Json.bool(isStale(c, book, now))),
    ]);
  };

  func eventsJson(events : [LogEvent], tz : Int) : Json.Json {
    Json.arr(Array.map<LogEvent, Json.Json>(events, func(e) {
      Json.obj([("at", Json.str(fmtLocal(e.at, tz))), ("event", Json.str(e.event))]);
    }));
  };

  func activityJson(a : Activity, tz : Int) : Json.Json {
    Json.obj([
      ("activity_id", Json.int(a.id)),
      ("kind", Json.str(kindText(a.kind))),
      ("direction", Json.str(directionText(a.direction))),
      ("at", Json.str(fmtLocal(a.at, tz))),
      ("summary", Json.str(a.summary)),
      ("deal_id", optJsonNat(a.dealId)),
    ]);
  };

  func followUpJson(f : FollowUp, tz : Int, now : Int) : Json.Json {
    let contactName = switch (getContact(f.contactId)) { case (?c) c.name; case (null) "?" };
    Json.obj([
      ("follow_up_id", Json.int(f.id)),
      ("contact_id", Json.int(f.contactId)),
      ("contact_name", Json.str(contactName)),
      ("task", Json.str(f.task)),
      ("due", Json.str(fmtLocal(f.dueAt, tz))),
      ("due_in", Json.str(fmtAgo(now, f.dueAt))),
      ("overdue", Json.bool(f.status == #open and f.dueAt < now)),
      ("status", Json.str(followStatusText(f.status))),
      ("outcome", optJsonText(f.outcome)),
      ("deal_id", optJsonNat(f.dealId)),
    ]);
  };

  func dealJson(d : Deal, tz : Int, includeEvents : Bool) : Json.Json {
    let contactName = switch (getContact(d.contactId)) { case (?c) c.name; case (null) "?" };
    let base = [
      ("deal_id", Json.int(d.id)),
      ("contact_id", Json.int(d.contactId)),
      ("contact_name", Json.str(contactName)),
      ("title", Json.str(d.title)),
      ("stage", Json.str(dealStageText(d.stage))),
      ("value_usd", switch (d.valueCents) { case (?v) usdFloat(v); case (null) Json.nullable() }),
      ("expected_close", switch (d.expectedCloseDay) { case (?day) Json.str(fmtDate(day)); case (null) Json.nullable() }),
      ("lost_reason", optJsonText(d.lostReason)),
      ("closed", switch (d.closedAt) { case (?t) Json.str(fmtLocal(t, tz)); case (null) Json.nullable() }),
      ("opened", Json.str(fmtLocal(d.createdAt, tz))),
    ];
    if (not includeEvents) return Json.obj(base);
    Json.obj(Array.append(base, [("history", eventsJson(d.events, tz))]));
  };

  func repliesJson(rs : [Reply], tz : Int) : Json.Json {
    Json.arr(Array.map<Reply, Json.Json>(rs, func(r) {
      Json.obj([("at", Json.str(fmtLocal(r.at, tz))), ("text", Json.str(r.text))]);
    }));
  };

  func inquiryOwnerJson(q : Inquiry, tz : Int, now : Int) : Json.Json {
    Json.obj([
      ("inquiry_id", Json.int(q.id)),
      ("contact_id", Json.int(q.contactId)),
      ("from", Json.str(Principal.toText(q.sender))),
      ("sender_name", optJsonText(q.senderName)),
      ("reply_to", optJsonText(q.replyTo)),
      ("subject", Json.str(q.subject)),
      ("message", Json.str(q.message)),
      ("status", Json.str(inquiryStatusText(q.status))),
      ("received", Json.str(fmtLocal(q.createdAt, tz))),
      ("waiting", Json.str(fmtAgo(now, q.createdAt))),
      ("replies", repliesJson(q.replies, tz)),
    ]);
  };

  /// Ready-made arguments for the next server in the chain. No call is made:
  /// the agent holding both keys decides whether to run them.
  func handoffJson(c : Contact, d : ?Deal) : Json.Json {
    let reach = switch (c.phone, c.email) {
      case (?ph, _) ?ph;
      case (null, ?em) ?em;
      case (null, null) null;
    };
    let notes = switch (d) { case (?deal) ?("Won deal #" # Nat.toText(deal.id) # ": " # deal.title); case (null) null };
    let bookArgs = Buffer.Buffer<(Text, Json.Json)>(4);
    bookArgs.add(("customer_name", Json.str(c.name)));
    switch (reach) { case (?r) bookArgs.add(("contact", Json.str(r))); case (null) {} };
    switch (c.address) { case (?a) bookArgs.add(("location", Json.str(a))); case (null) {} };
    switch (notes) { case (?n) bookArgs.add(("notes", Json.str(n))); case (null) {} };

    let invoiceArgs = Buffer.Buffer<(Text, Json.Json)>(3);
    switch (d) {
      case (?deal) {
        invoiceArgs.add(("title", Json.str(deal.title)));
        switch (deal.valueCents) { case (?v) invoiceArgs.add(("amount_usd", usdFloat(v))); case (null) {} };
      };
      case (null) invoiceArgs.add(("title", Json.str("Work for " # c.name)));
    };
    switch (c.agent) { case (?a) invoiceArgs.add(("payer", Json.str(Principal.toText(a)))); case (null) {} };

    Json.obj([
      (
        "dispatch_scheduler_book",
        Json.obj([
          ("server", Json.str("Appointment & Dispatch Scheduler")),
          ("tool", Json.str("book")),
          ("arguments", Json.obj(Buffer.toArray(bookArgs))),
          ("still_needed", Json.str("service_id and start — get both from find_slots.")),
        ]),
      ),
      (
        "invoice_desk_create_invoice",
        Json.obj([
          ("server", Json.str("Invoice & Payments Desk")),
          ("tool", Json.str("create_invoice")),
          ("arguments", Json.obj(Buffer.toArray(invoiceArgs))),
          ("note", Json.str(switch (c.agent) { case (?_) "payer is the principal that sent this contact's inquiries."; case (null) "No payer principal on file; the invoice will be open to any payer unless you add one." })),
        ]),
      ),
    ]);
  };

  // --- TOOL SCHEMAS ---

  func schemaProp(name : Text, jsonType : Text, description : Text) : (Text, Json.Json) {
    (name, Json.obj([("type", Json.str(jsonType)), ("description", Json.str(description))]));
  };

  func arrayProp(name : Text, itemType : Text, description : Text) : (Text, Json.Json) {
    (
      name,
      Json.obj([
        ("type", Json.str("array")),
        ("items", Json.obj([("type", Json.str(itemType))])),
        ("description", Json.str(description)),
      ]),
    );
  };

  func objSchema(props : [(Text, Json.Json)], required : [Text]) : Json.Json {
    Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj(props)),
      ("required", Json.arr(Array.map<Text, Json.Json>(required, Json.str))),
    ]);
  };

  func tool(name : Text, title : Text, description : Text, schema : Json.Json) : McpTypes.Tool {
    {
      name = name;
      title = ?title;
      description = ?description;
      payment = null;
      inputSchema = schema;
      outputSchema = null;
    };
  };

  transient let dueHelp : Text = "When: 'YYYY-MM-DD HH:MM' in your local time, or a day — 'YYYY-MM-DD', 'today', 'tomorrow', '+3' (days from today) — which means 09:00.";

  transient let tools : [McpTypes.Tool] = [
    tool(
      "setup_crm",
      "Set Up CRM",
      "Create or update your book — the CRM everything else hangs off. One principal owns one book. Set your UTC offset here: follow-up times are read and written in your local time, and there is no DST database on-chain, so shift it twice a year if you observe DST. listed=true opens an inbox: your business appears in find_businesses and any customer's agent can send you an inquiry, which lands as a lead. Omitted fields keep their current values.",
      objSchema(
        [
          schemaProp("name", "string", "Business name, e.g. 'Legacy Garage Doors' (1-120 chars)."),
          schemaProp("description", "string", "What you do, shown to inquiring agents when listed (up to 2000 chars)."),
          schemaProp("contact", "string", "Public phone, email, or website."),
          schemaProp("service_area", "string", "Where you work, e.g. 'Hattiesburg & Purvis, MS'."),
          schemaProp("timezone_offset_minutes", "number", "Minutes from UTC, e.g. -300 for US Central Daylight Time. Default 0."),
          schemaProp("stale_days", "number", "A lead untouched this many days with nothing scheduled is flagged stale. Default 14."),
          schemaProp("listed", "boolean", "Open the inquiry inbox and appear in find_businesses. Default false — your book is private until you choose otherwise."),
          schemaProp("intake_note", "string", "What an inquiring agent should include, e.g. 'Door size, opener brand, and the address.'"),
        ],
        ["name"],
      ),
    ),
    tool(
      "find_businesses",
      "Find Businesses",
      "Discover businesses whose inbox is open to inquiries. Returns each one's business principal (what submit_inquiry needs), what they do, where, and what they want an inquiry to include. Open to any authenticated caller.",
      objSchema(
        [
          schemaProp("query", "string", "Optional: match against name, description, and service area, e.g. 'garage' or 'Hattiesburg'."),
          schemaProp("limit", "number", "Max results, default 20, up to 50."),
        ],
        [],
      ),
    ),
    tool(
      "submit_inquiry",
      "Submit Inquiry",
      "Send an inquiry to a listed business on behalf of your user. It lands in their CRM as a lead (or on the contact they already have for you) and on their agenda. Check my_inquiries for the reply. Limits: 3 unanswered inquiries per business, 10 inquiries per day overall.",
      objSchema(
        [
          schemaProp("business", "string", "The business principal from find_businesses."),
          schemaProp("message", "string", "What you need — specific beats polite (10-2000 chars). Include what the business's intake_note asks for."),
          schemaProp("subject", "string", "Short subject line, e.g. 'Broken spring, door stuck open' (up to 120 chars)."),
          schemaProp("name", "string", "Who the inquiry is for, e.g. 'Dana Whitfield'."),
          schemaProp("contact_info", "string", "How they'd like to be reached: a phone number or email."),
        ],
        ["business", "message"],
      ),
    ),
    tool(
      "my_inquiries",
      "My Inquiries",
      "Inquiries you have sent to businesses, newest first, with their status and every reply.",
      objSchema(
        [
          schemaProp("status", "string", "Optional filter: open | replied | closed."),
          schemaProp("limit", "number", "Max results, default 20, up to 50."),
        ],
        [],
      ),
    ),
    tool(
      "reply_to_inquiry",
      "Reply to Inquiry",
      "Answer an inquiry in your inbox. The sender's agent sees the reply in my_inquiries, and it is logged on the contact's timeline as an outbound reply. close=true also closes the inquiry (message is optional when closing).",
      objSchema(
        [
          schemaProp("inquiry_id", "number", "The inquiry, from get_agenda or get_contact."),
          schemaProp("message", "string", "Your reply (1-2000 chars)."),
          schemaProp("close", "boolean", "Close the inquiry after this reply. Default false."),
        ],
        ["inquiry_id"],
      ),
    ),
    tool(
      "add_contact",
      "Add or Update Contact",
      "Add a lead, customer, or company to your book — or pass contact_id to update one. Duplicates are refused, not silently created: a matching email, phone number (last 10 digits), or name+company returns the existing contact's id instead. Pass allow_duplicate=true if it really is a different person. On update, omitted fields keep their values, tags replaces the whole tag list, and clear_fields blanks fields out.",
      objSchema(
        [
          schemaProp("contact_id", "number", "Update this contact instead of creating one."),
          schemaProp("name", "string", "Person or company name (1-120 chars). Required when creating."),
          schemaProp("company", "string", "Company, if the contact is a person at one."),
          schemaProp("email", "string", "Email address."),
          schemaProp("phone", "string", "Phone number, any format."),
          schemaProp("address", "string", "Street address or job site — carried into the Dispatch Scheduler hand-off."),
          schemaProp("source", "string", "Where they came from: 'referral', 'google', 'yard sign', 'repeat'…"),
          arrayProp("tags", "string", "Labels, e.g. ['commercial', 'warranty']. Lowercased; up to 12. Replaces existing tags on update."),
          schemaProp("notes", "string", "Standing notes about this contact (up to 2000 chars). For what happened on a given day, use log_activity."),
          schemaProp("stage", "string", "On create only: lead (default), qualified, or customer. Use set_stage later."),
          arrayProp("clear_fields", "string", "On update: fields to blank — any of company, email, phone, address, source, notes, tags."),
          schemaProp("allow_duplicate", "boolean", "Create or save even though it matches an existing contact."),
        ],
        [],
      ),
    ),
    tool(
      "find_contacts",
      "Find Contacts",
      "Search your book. Matches text against name, company, email, phone, source, and tags; filter by stage, tag, source, or staleness. Most recently touched first. Archived contacts are hidden unless you ask for stage=archived or stage=all.",
      objSchema(
        [
          schemaProp("query", "string", "Text to match, e.g. 'whitfield', '555-0142', or 'commercial'."),
          schemaProp("stage", "string", "lead | qualified | customer | lost | archived | open (lead + qualified) | all."),
          schemaProp("tag", "string", "Only contacts with this tag."),
          schemaProp("source", "string", "Only contacts from this source."),
          schemaProp("stale_only", "boolean", "Only stale leads: open stage, untouched past your stale_days, nothing scheduled."),
          schemaProp("limit", "number", "Max results, default 25, up to 50."),
        ],
        [],
      ),
    ),
    tool(
      "get_contact",
      "Get Contact",
      "Everything about one contact: details, stage history, timeline (newest first), open and past follow-ups, deals, inquiries, and ready-made hand-off arguments for Dispatch Scheduler and Invoice Desk.",
      objSchema(
        [
          schemaProp("contact_id", "number", "The contact."),
          schemaProp("timeline_limit", "number", "How many recent activities to include, default 30, up to 100."),
        ],
        ["contact_id"],
      ),
    ),
    tool(
      "set_stage",
      "Set Contact Stage",
      "Move a contact: lead → qualified → customer, or to lost or archived. A reason is required for lost and recorded permanently in the contact's history. Winning a deal promotes the contact to customer automatically.",
      objSchema(
        [
          schemaProp("contact_id", "number", "The contact."),
          schemaProp("stage", "string", "lead | qualified | customer | lost | archived."),
          schemaProp("reason", "string", "Why. Required for lost, e.g. 'Went with a cheaper quote'."),
        ],
        ["contact_id", "stage"],
      ),
    ),
    tool(
      "log_activity",
      "Log Activity",
      "Record an interaction on a contact's timeline: a call, email, text, meeting, site visit, or internal note. The timeline is append-only — correct a mistake with a new note. Anything but a note counts as a touch and resets the stale clock. Optionally close the follow-up this fulfilled and schedule the next step in the same call.",
      objSchema(
        [
          schemaProp("contact_id", "number", "The contact."),
          schemaProp("kind", "string", "call | email | text | meeting | visit | note."),
          schemaProp("summary", "string", "What happened and what was agreed (1-2000 chars)."),
          schemaProp("direction", "string", "inbound | outbound | internal. Defaults: note = internal, everything else = outbound."),
          schemaProp("at", "string", "When it happened, 'YYYY-MM-DD HH:MM' local. Defaults to now; may be backdated, never future."),
          schemaProp("deal_id", "number", "Optional: the deal this was about."),
          schemaProp("completes_follow_up_id", "number", "Optional: an open follow-up this interaction fulfilled; it is marked done with this summary as the outcome."),
          schemaProp("next_follow_up", "string", "Optional: schedule the next step. " # dueHelp),
          schemaProp("next_task", "string", "What the next step is, e.g. 'Call back with the quote'. Required with next_follow_up."),
        ],
        ["contact_id", "kind", "summary"],
      ),
    ),
    tool(
      "schedule_follow_up",
      "Schedule Follow-Up",
      "Put a dated next step on a contact. It shows on get_agenda when due, and a lead with a follow-up scheduled is never flagged stale.",
      objSchema(
        [
          schemaProp("contact_id", "number", "The contact."),
          schemaProp("due", "string", dueHelp),
          schemaProp("task", "string", "What to do, e.g. 'Send the opener quote' (1-300 chars)."),
          schemaProp("deal_id", "number", "Optional: the deal it moves forward."),
        ],
        ["contact_id", "due", "task"],
      ),
    ),
    tool(
      "complete_follow_up",
      "Complete Follow-Up",
      "Close a follow-up as done (with what came of it) or cancelled. log_as records the outcome as a real interaction on the timeline — a call, email, text, meeting, or visit — so it also counts as a touch. Optionally chain the next follow-up.",
      objSchema(
        [
          schemaProp("follow_up_id", "number", "The follow-up."),
          schemaProp("outcome", "string", "What came of it (up to 2000 chars). Required unless cancelling."),
          schemaProp("cancel", "boolean", "Cancel instead of completing."),
          schemaProp("log_as", "string", "Optional: call | email | text | meeting | visit — also log the outcome as that activity."),
          schemaProp("next_follow_up", "string", "Optional: schedule the next step. " # dueHelp),
          schemaProp("next_task", "string", "What the next step is. Required with next_follow_up."),
        ],
        ["follow_up_id"],
      ),
    ),
    tool(
      "get_agenda",
      "Get Agenda",
      "Your day: overdue follow-ups, what is due today, what is coming up, inquiries waiting on a reply, stale leads nobody is working, and open deals past their expected close date. Start here.",
      objSchema(
        [schemaProp("days", "number", "How far ahead 'upcoming' looks, default 7, up to 30.")],
        [],
      ),
    ),
    tool(
      "add_deal",
      "Add or Update Deal",
      "Open a priced opportunity on a contact — a quote, a job, a contract — or pass deal_id to change its title, value, or expected close date. Opening a deal on a lead moves the lead to qualified. The value is a quote only; nothing here moves money.",
      objSchema(
        [
          schemaProp("deal_id", "number", "Update this deal instead of creating one."),
          schemaProp("contact_id", "number", "The contact. Required when creating."),
          schemaProp("title", "string", "What it is, e.g. 'Double door + opener install' (1-120 chars). Required when creating."),
          schemaProp("value_usd", "number", "Quoted value in USD, e.g. 1850 or 249.99."),
          schemaProp("expected_close", "string", "When you expect it to close: 'YYYY-MM-DD', 'tomorrow', or '+14'."),
          schemaProp("stage", "string", "On create only: new (default), contacted, quoted, or negotiating."),
          schemaProp("clear_value", "boolean", "On update: remove the value."),
          schemaProp("clear_expected_close", "boolean", "On update: remove the expected close date."),
        ],
        [],
      ),
    ),
    tool(
      "move_deal",
      "Move Deal",
      "Move a deal through the pipeline: new → contacted → quoted → negotiating → won or lost. Lost needs a reason. Won promotes the contact to customer and returns ready-made arguments to book the job in Dispatch Scheduler and bill it in Invoice Desk. A closed deal can be reopened by moving it back to an open stage.",
      objSchema(
        [
          schemaProp("deal_id", "number", "The deal."),
          schemaProp("stage", "string", "new | contacted | quoted | negotiating | won | lost."),
          schemaProp("reason", "string", "Why. Required for lost, e.g. 'Price — went with a competitor'."),
        ],
        ["deal_id", "stage"],
      ),
    ),
    tool(
      "get_pipeline",
      "Get Pipeline",
      "The numbers: open deals and value by stage, won and lost totals, win rate, average days to close, won value in the last 30 days, contacts by stage, and lead-to-customer conversion by source.",
      objSchema([], []),
    ),
    tool(
      "merge_contacts",
      "Merge Contacts",
      "Fold a duplicate into the contact you are keeping. Timeline, follow-ups, deals, and inquiries all move over; blank fields fill from the duplicate; tags combine; the further-along stage wins. Differing emails, phones, and addresses are preserved in the kept contact's notes. The duplicate becomes a pointer to the survivor.",
      objSchema(
        [
          schemaProp("keep_id", "number", "The contact that survives."),
          schemaProp("merge_id", "number", "The duplicate to fold in."),
        ],
        ["keep_id", "merge_id"],
      ),
    ),
    tool(
      "forget_contact",
      "Forget Contact",
      "Permanently erase a contact's personal data — name, email, phone, address, notes, tags, timeline text, follow-up text, deal titles, and inquiry text — for a deletion request. Dates, stages, and deal values stay so your pipeline numbers remain true. Cannot be undone.",
      objSchema(
        [
          schemaProp("contact_id", "number", "The contact to erase."),
          schemaProp("confirm", "boolean", "Must be true. Erasure is irreversible."),
        ],
        ["contact_id", "confirm"],
      ),
    ),
  ];

  // --- TOOL IMPLEMENTATIONS ---

  type ToolCb = (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ();

  func fail(cb : ToolCb, msg : Text) { cb(#ok(errorResult(msg))) };

  func requireAuth(auth : ?AuthTypes.AuthInfo, cb : ToolCb) : ?Principal {
    switch (callerPrincipal(auth)) {
      case (?p) ?p;
      case (null) {
        fail(cb, "Authentication required: call this tool with a valid x-api-key.");
        null;
      };
    };
  };

  func requireBook(p : Principal, cb : ToolCb) : ?Book {
    switch (getBook(p)) {
      case (?b) ?b;
      case (null) {
        fail(cb, "You have no CRM book on this server yet. Call setup_crm first — it takes one field, your business name.");
        null;
      };
    };
  };

  /// A live contact in the caller's book. Another book's id reads as not found.
  func ownedContact(p : Principal, id : Nat, cb : ToolCb) : ?Contact {
    let notFound = "No contact with id " # Nat.toText(id) # " in your book. Use find_contacts to look it up.";
    let ?c = getContact(id) else { fail(cb, notFound); return null };
    if (c.owner != p) { fail(cb, notFound); return null };
    switch (c.mergedInto) {
      case (?k) { fail(cb, "Contact " # Nat.toText(id) # " was merged into contact " # Nat.toText(k) # " — use that id."); return null };
      case (null) {};
    };
    switch (c.erasedAt) {
      case (?_) { fail(cb, "Contact " # Nat.toText(id) # " was erased at a deletion request; it can no longer be changed."); return null };
      case (null) {};
    };
    ?c;
  };

  func ownedDeal(p : Principal, id : Nat, cb : ToolCb) : ?Deal {
    switch (getDeal(id)) {
      case (?d) { if (d.owner == p) return ?d };
      case (null) {};
    };
    fail(cb, "No deal with id " # Nat.toText(id) # " in your book. get_pipeline or get_contact lists your deals.");
    null;
  };

  func ownedFollowUp(p : Principal, id : Nat, cb : ToolCb) : ?FollowUp {
    switch (getFollowUp(id)) {
      case (?f) { if (f.owner == p) return ?f };
      case (null) {};
    };
    fail(cb, "No follow-up with id " # Nat.toText(id) # " in your book. get_agenda lists your open follow-ups.");
    null;
  };

  /// A deal_id argument that, if given, must be a deal on this contact.
  func dealOnContact(p : Principal, args : McpTypes.JsonValue, cid : Nat, cb : ToolCb) : { #none; #ok : Nat; #failed } {
    switch (optNat(args, "deal_id")) {
      case (null) #none;
      case (?id) {
        let ?d = ownedDeal(p, id, cb) else return #failed;
        if (d.contactId != cid) {
          fail(cb, "Deal " # Nat.toText(id) # " belongs to contact " # Nat.toText(d.contactId) # ", not " # Nat.toText(cid) # ".");
          return #failed;
        };
        #ok(id);
      };
    };
  };

  func optLen(args : McpTypes.JsonValue, field : Text, max : Nat) : { #absent; #ok : Text; #err : Text } {
    switch (optText(args, field)) {
      case (null) #absent;
      case (?t) {
        switch (requireLen(t, field, 1, max)) {
          case (?e) #err(e);
          case (null) #ok(t);
        };
      };
    };
  };

  // --- setup_crm ---

  func setupCrmTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?name = optText(args, "name") else return fail(cb, "'name' is required — your business name, e.g. 'Legacy Garage Doors'.");
    switch (requireLen(name, "name", 1, maxNameChars)) { case (?e) return fail(cb, e); case (null) {} };
    let existing = getBook(p);
    let now = Time.now();

    let tz = switch (optInt(args, "timezone_offset_minutes")) {
      case (?v) v;
      case (null) switch (existing) { case (?b) b.tzOffsetMinutes; case (null) 0 };
    };
    if (tz < -840 or tz > 840) return fail(cb, "'timezone_offset_minutes' must be between -840 and 840 (UTC-14 to UTC+14).");

    let stale = switch (optNat(args, "stale_days")) {
      case (?v) v;
      case (null) switch (existing) { case (?b) b.staleDays; case (null) 14 };
    };
    if (stale < 1 or stale > 365) return fail(cb, "'stale_days' must be between 1 and 365.");

    func keep(field : Text, max : Nat, prev : ?Text) : { #ok : ?Text; #err : Text } {
      switch (optLen(args, field, max)) {
        case (#ok(t)) #ok(?t);
        case (#err(e)) #err(e);
        case (#absent) #ok(prev);
      };
    };
    let prevDesc = switch (existing) { case (?b) b.description; case (null) null };
    let prevContact = switch (existing) { case (?b) b.contact; case (null) null };
    let prevArea = switch (existing) { case (?b) b.serviceArea; case (null) null };
    let prevIntake = switch (existing) { case (?b) b.intakeNote; case (null) null };
    let desc = switch (keep("description", maxTextChars, prevDesc)) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let contact = switch (keep("contact", maxFieldChars, prevContact)) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let area = switch (keep("service_area", maxFieldChars, prevArea)) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let intake = switch (keep("intake_note", maxTextChars, prevIntake)) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let listed = switch (optBool(args, "listed")) {
      case (?v) v;
      case (null) switch (existing) { case (?b) b.listed; case (null) false };
    };

    let book : Book = {
      owner = p;
      name = name;
      description = desc;
      contact = contact;
      serviceArea = area;
      tzOffsetMinutes = tz;
      staleDays = stale;
      listed = listed;
      intakeNote = intake;
      createdAt = switch (existing) { case (?b) b.createdAt; case (null) now };
    };
    Map.set(books, phash, p, book);

    let message = switch (existing) {
      case (null) {
        if (listed) "Book created and listed: customers' agents can now find you with find_businesses and send inquiries. Next: add_contact for the people you already know, and get_agenda each morning." else "Book created (private). Next: add_contact for the people you already know, log_activity as you talk to them, and get_agenda each morning. Set listed=true when you want an inquiry inbox.";
      };
      case (?_) "Book updated. Fields you did not pass kept their previous values.";
    };
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(message)),
      ("book", bookJson(book, true)),
      ("local_time_now", Json.str(fmtLocal(now, tz))),
    ]))));
  };

  // --- find_businesses ---

  func unansweredCount(business : Principal) : Nat {
    var n = 0;
    for (id in idsOf(inquiryIdsByBusiness, business).vals()) {
      switch (getInquiry(id)) { case (?q) { if (q.status == #open) n += 1 }; case (null) {} };
    };
    n;
  };

  func findBusinessesTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?_p = requireAuth(auth, cb) else return;
    let needle = switch (optText(args, "query")) { case (?q) ?lower(q); case (null) null };
    let limit = Nat.min(switch (optNat(args, "limit")) { case (?n) Nat.max(n, 1); case (null) 20 }, maxListResults);

    let out = Buffer.Buffer<Json.Json>(limit);
    var matched = 0;
    for ((_, b) in Map.entries(books)) {
      if (b.listed) {
        let hit = switch (needle) {
          case (null) true;
          case (?q) contains(b.name, q) or optContains(b.description, q) or optContains(b.serviceArea, q);
        };
        if (hit) {
          matched += 1;
          if (out.size() < limit) {
            out.add(Json.obj([
              ("business", Json.str(Principal.toText(b.owner))),
              ("name", Json.str(b.name)),
              ("description", optJsonText(b.description)),
              ("service_area", optJsonText(b.serviceArea)),
              ("contact", optJsonText(b.contact)),
              ("intake_note", optJsonText(b.intakeNote)),
              ("accepting_inquiries", Json.bool(unansweredCount(b.owner) < maxUnansweredPerBook)),
            ]));
          };
        };
      };
    };
    let message = if (matched == 0) "No listed businesses match. Businesses opt in to inquiries with setup_crm listed=true." else "Pass a business principal to submit_inquiry.";
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(message)),
      ("total_matches", Json.int(matched)),
      ("businesses", Json.arr(Buffer.toArray(out))),
    ]))));
  };

  // --- contacts: creation shared by add_contact and submit_inquiry ---

  func contactCapProblem(owner : Principal) : ?Text {
    if (idsOf(contactIdsByOwner, owner).size() >= maxContactsPerBook) {
      return ?("This book has reached " # Nat.toText(maxContactsPerBook) # " contacts. Archive or merge before adding more.");
    };
    null;
  };

  func insertContact(c : Contact) {
    putContact(c);
    indexAdd(contactIdsByOwner, c.owner, c.id);
  };

  func blankContact(owner : Principal, name : Text, stage : Stage, now : Int) : Contact {
    let c : Contact = {
      id = nextContactId;
      owner = owner;
      name = name;
      company = null;
      email = null;
      phone = null;
      address = null;
      source = null;
      tags = [];
      notes = null;
      agent = null;
      stage = stage;
      stageReason = null;
      lastTouchAt = null;
      mergedInto = null;
      erasedAt = null;
      events = [{ at = now; event = "Added as " # stageText(stage) # "." }];
      createdAt = now;
      updatedAt = now;
    };
    nextContactId += 1;
    c;
  };

  /// Existing live contacts this record would duplicate, with the reason.
  func duplicatesOf(owner : Principal, exclude : ?Nat, name : ?Text, company : ?Text, email : ?Text, phone : ?Text) : [Json.Json] {
    let emailKey = switch (email) { case (?e) ?normEmail(e); case (null) null };
    let phoneK = switch (phone) { case (?ph) phoneKey(ph); case (null) null };
    let nk = switch (name) { case (?n) ?nameKey(n, company); case (null) null };
    let out = Buffer.Buffer<Json.Json>(2);
    for (c in bookContacts(owner).vals()) {
      let skip = switch (exclude) { case (?x) x == c.id; case (null) false };
      if (not skip) {
        var why : ?Text = null;
        switch (emailKey, c.email) {
          case (?k, ?e) { if (normEmail(e) == k) why := ?"same email" };
          case (_, _) {};
        };
        if (why == null) {
          switch (phoneK, c.phone) {
            case (?k, ?ph) { if (phoneKey(ph) == ?k) why := ?"same phone number" };
            case (_, _) {};
          };
        };
        if (why == null) {
          switch (nk) {
            case (?k) { if (nameKey(c.name, c.company) == k) why := ?"same name and company" };
            case (null) {};
          };
        };
        switch (why) {
          case (?w) out.add(Json.obj([
            ("contact_id", Json.int(c.id)),
            ("name", Json.str(c.name)),
            ("stage", Json.str(stageText(c.stage))),
            ("matched_on", Json.str(w)),
          ]));
          case (null) {};
        };
      };
    };
    Buffer.toArray(out);
  };

  // --- submit_inquiry ---

  func submitInquiryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?bizText = optText(args, "business") else return fail(cb, "'business' is required — a business principal from find_businesses.");
    let ?biz = parsePrincipal(bizText) else return fail(cb, "'" # clip(bizText, 70) # "' is not a principal. Copy the 'business' field from find_businesses.");
    let ?book = getBook(biz) else return fail(cb, "No business with that principal on this server. Use find_businesses.");
    if (not book.listed) return fail(cb, book.name # " is not taking inquiries here.");
    if (biz == p) return fail(cb, "That is your own book. Use add_contact and log_activity for your own records.");

    let ?message = optText(args, "message") else return fail(cb, "'message' is required — what you need, 10-2000 characters.");
    switch (requireLen(message, "message", 10, maxTextChars)) { case (?e) return fail(cb, e); case (null) {} };
    let subject = switch (optLen(args, "subject", maxNameChars)) {
      case (#ok(s)) s;
      case (#err(e)) return fail(cb, e);
      case (#absent) clip(message, 60);
    };
    let senderName = switch (optLen(args, "name", maxNameChars)) {
      case (#ok(s)) ?s;
      case (#err(e)) return fail(cb, e);
      case (#absent) null;
    };
    let replyTo = switch (optLen(args, "contact_info", maxFieldChars)) {
      case (#ok(s)) ?s;
      case (#err(e)) return fail(cb, e);
      case (#absent) null;
    };

    let now = Time.now();
    var openHere = 0;
    var lastDay = 0;
    for (id in idsOf(inquiryIdsBySender, p).vals()) {
      switch (getInquiry(id)) {
        case (?q) {
          if (q.business == biz and q.status == #open) openHere += 1;
          if (now - q.createdAt < nanosPerDay) lastDay += 1;
        };
        case (null) {};
      };
    };
    if (openHere >= maxOpenInquiriesPerSenderPerBook) {
      return fail(cb, "You already have " # Nat.toText(openHere) # " unanswered inquiries with " # book.name # ". Wait for a reply — check my_inquiries.");
    };
    if (lastDay >= maxInquiriesPerSenderPerDay) {
      return fail(cb, "Daily limit reached: " # Nat.toText(maxInquiriesPerSenderPerDay) # " inquiries per 24 hours.");
    };
    if (unansweredCount(biz) >= maxUnansweredPerBook) {
      return fail(cb, book.name # "'s inbox is full. Reach them directly" # (switch (book.contact) { case (?c) " at " # c; case (null) "" }) # ".");
    };

    // Land on the contact this sender already has in this book, or create one.
    let agentKey = Principal.toText(biz) # "#" # Principal.toText(p);
    let existing = switch (Map.get(contactByAgent, thash, agentKey)) {
      case (?cid) resolveLive(cid);
      case (null) null;
    };
    let emailIn = switch (replyTo) { case (?r) { if (looksLikeEmail(r)) ?Text.trim(r, #char ' ') else null }; case (null) null };
    let phoneIn = switch (replyTo, emailIn) {
      case (?r, null) { if (phoneKey(r) != null) ?Text.trim(r, #char ' ') else null };
      case (_, _) null;
    };

    var created = false;
    let contact : Contact = switch (existing) {
      case (?c) {
        var c2 = c;
        if (c2.email == null and emailIn != null) c2 := { c2 with email = emailIn };
        if (c2.phone == null and phoneIn != null) c2 := { c2 with phone = phoneIn };
        if (c2.agent == null) c2 := { c2 with agent = ?p };
        if (c2.stage == #lost or c2.stage == #archived) {
          c2 := { c2 with stage = #lead; stageReason = null; events = pushEvent(c2.events, "Reopened as lead: a new inquiry arrived (was " # stageText(c2.stage) # ").", now) };
        };
        c2;
      };
      case (null) {
        switch (contactCapProblem(biz)) {
          case (?_) return fail(cb, book.name # " cannot take new contacts right now. Reach them directly" # (switch (book.contact) { case (?c) " at " # c; case (null) "" }) # ".");
          case (null) {};
        };
        let name = switch (senderName) { case (?n) n; case (null) "Agent " # shortPrincipal(p) };
        let fresh = blankContact(biz, name, #lead, now);
        created := true;
        {
          fresh with
          email = emailIn;
          phone = phoneIn;
          source = ?"inquiry";
          agent = ?p;
          notes = switch (replyTo, emailIn, phoneIn) {
            case (?r, null, null) ?("Asked to be reached via: " # r);
            case (_, _, _) null;
          };
          events = [{ at = now; event = "Added as lead from inquiry." }];
        };
      };
    };
    switch (activityCapProblem(biz, contact.id)) {
      case (?_) return fail(cb, book.name # " cannot take more inquiries on this contact right now.");
      case (null) {};
    };
    if (created) insertContact(contact) else putContact(contact);
    Map.set(contactByAgent, thash, agentKey, contact.id);

    let q : Inquiry = {
      id = nextInquiryId;
      business = biz;
      sender = p;
      contactId = contact.id;
      subject = subject;
      message = message;
      senderName = senderName;
      replyTo = replyTo;
      status = #open;
      replies = [];
      erased = false;
      createdAt = now;
    };
    nextInquiryId += 1;
    putInquiry(q);
    indexAdd(inquiryIdsByBusiness, biz, q.id);
    indexAdd(inquiryIdsBySender, p, q.id);
    indexAddN(inquiryIdsByContact, contact.id, q.id);
    ignore recordActivity(biz, contact, null, #inquiry, #inbound, "Inquiry #" # Nat.toText(q.id) # " — " # subject # ": " # message, now, now);

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Delivered to " # book.name # ". It is on their agenda now; check my_inquiries for the reply.")),
      ("inquiry_id", Json.int(q.id)),
      ("business", Json.str(book.name)),
      ("subject", Json.str(subject)),
      ("status", Json.str(inquiryStatusText(q.status))),
    ]))));
  };

  // --- my_inquiries ---

  func myInquiriesTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let filter : ?InquiryStatus = switch (optText(args, "status")) {
      case (null) null;
      case (?t) switch (lower(t)) {
        case ("open") ?#open;
        case ("replied") ?#replied;
        case ("closed") ?#closed;
        case (_) return fail(cb, "'status' must be open, replied, or closed.");
      };
    };
    let limit = Nat.min(switch (optNat(args, "limit")) { case (?n) Nat.max(n, 1); case (null) 20 }, maxListResults);
    let ids = idsOf(inquiryIdsBySender, p);
    let out = Buffer.Buffer<Json.Json>(limit);
    var i = ids.size();
    while (i > 0 and out.size() < limit) {
      i -= 1;
      switch (getInquiry(ids[i])) {
        case (?q) {
          let hit = switch (filter) { case (?s) q.status == s; case (null) true };
          if (hit) {
            let (bizName, tz) = switch (getBook(q.business)) { case (?b) (b.name, b.tzOffsetMinutes); case (null) ("(unknown)", 0) };
            out.add(Json.obj([
              ("inquiry_id", Json.int(q.id)),
              ("business", Json.str(bizName)),
              ("business_principal", Json.str(Principal.toText(q.business))),
              ("subject", Json.str(q.subject)),
              ("message", Json.str(q.message)),
              ("status", Json.str(inquiryStatusText(q.status))),
              ("sent", Json.str(fmtLocal(q.createdAt, tz) # " (business local time)")),
              ("replies", repliesJson(q.replies, tz)),
            ]));
          };
        };
        case (null) {};
      };
    };
    let message = if (ids.size() == 0) "You have not sent any inquiries. find_businesses, then submit_inquiry." else Nat.toText(out.size()) # " inquiries shown, newest first.";
    cb(#ok(okResult(Json.obj([("message", Json.str(message)), ("inquiries", Json.arr(Buffer.toArray(out)))]))));
  };

  // --- reply_to_inquiry ---

  func replyToInquiryTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let ?id = optNat(args, "inquiry_id") else return fail(cb, "'inquiry_id' is required.");
    let notFound = "No inquiry with id " # Nat.toText(id) # " in your inbox. get_agenda lists the ones waiting.";
    let ?q = getInquiry(id) else return fail(cb, notFound);
    if (q.business != p) return fail(cb, notFound);
    if (q.erased) return fail(cb, "Inquiry " # Nat.toText(id) # " was erased with its contact.");
    let close = switch (optBool(args, "close")) { case (?b) b; case (null) false };
    let message = switch (optLen(args, "message", maxTextChars)) {
      case (#ok(m)) ?m;
      case (#err(e)) return fail(cb, e);
      case (#absent) {
        if (not close) return fail(cb, "'message' is required unless you are closing the inquiry (close=true).");
        null;
      };
    };
    let now = Time.now();

    var replies = q.replies;
    switch (message) {
      case (?m) {
        if (replies.size() >= maxReplies) return fail(cb, "This inquiry has " # Nat.toText(maxReplies) # " replies already. Continue the conversation directly with the contact.");
        replies := Array.append(replies, [{ at = now; text = m }]);
      };
      case (null) {};
    };
    let status : InquiryStatus = if (close) #closed else #replied;
    let updated = { q with replies = replies; status = status };
    putInquiry(updated);

    switch (message, resolveLive(q.contactId)) {
      case (?m, ?c) {
        switch (activityCapProblem(p, c.id)) {
          case (null) ignore recordActivity(p, c, null, #reply, #outbound, "Reply to inquiry #" # Nat.toText(q.id) # ": " # m, now, now);
          case (?_) {}; // the reply still reaches the sender; only the timeline copy is skipped
        };
      };
      case (_, _) {};
    };

    let msg = switch (message, close) {
      case (?_, true) "Reply sent and inquiry closed.";
      case (?_, false) "Reply sent. The sender's agent sees it in my_inquiries.";
      case (null, _) "Inquiry closed without a reply.";
    };
    cb(#ok(okResult(Json.obj([("message", Json.str(msg)), ("inquiry", inquiryOwnerJson(updated, book.tzOffsetMinutes, now))]))));
  };

  // --- add_contact ---

  func addContactTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let now = Time.now();

    let existing : ?Contact = switch (optNat(args, "contact_id")) {
      case (?id) { let ?c = ownedContact(p, id, cb) else return; ?c };
      case (null) null;
    };
    let clearList = switch (readTextList(args, "clear_fields")) { case (?l) l; case (null) [] };
    for (f in clearList.vals()) {
      switch (lower(f)) {
        case ("company" or "email" or "phone" or "address" or "source" or "notes" or "tags") {};
        case (_) return fail(cb, "'" # f # "' cannot be cleared. clear_fields accepts company, email, phone, address, source, notes, tags.");
      };
    };
    if (existing == null and clearList.size() > 0) return fail(cb, "clear_fields only applies when updating (pass contact_id).");

    let name = switch (optLen(args, "name", maxNameChars), existing) {
      case (#ok(n), _) n;
      case (#err(e), _) return fail(cb, e);
      case (#absent, ?c) c.name;
      case (#absent, null) return fail(cb, "'name' is required to add a contact.");
    };

    func field(key : Text, max : Nat, prev : ?Text) : { #ok : ?Text; #err : Text } {
      if (hasField(clearList, key)) return #ok(null);
      switch (optLen(args, key, max)) {
        case (#ok(t)) #ok(?t);
        case (#err(e)) #err(e);
        case (#absent) #ok(prev);
      };
    };
    func prevOf(get : Contact -> ?Text) : ?Text {
      switch (existing) { case (?c) get(c); case (null) null };
    };
    let company = switch (field("company", maxNameChars, prevOf(func(c) { c.company }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let email = switch (field("email", maxFieldChars, prevOf(func(c) { c.email }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let phone = switch (field("phone", maxFieldChars, prevOf(func(c) { c.phone }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let address = switch (field("address", maxFieldChars, prevOf(func(c) { c.address }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let source = switch (field("source", maxNameChars, prevOf(func(c) { c.source }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };
    let notes = switch (field("notes", maxTextChars, prevOf(func(c) { c.notes }))) { case (#ok(v)) v; case (#err(e)) return fail(cb, e) };

    switch (optText(args, "email")) {
      case (?e) { if (not looksLikeEmail(e)) return fail(cb, "'" # clip(e, 60) # "' does not look like an email address.") };
      case (null) {};
    };
    switch (optText(args, "phone")) {
      case (?ph) { if (phoneKey(ph) == null) return fail(cb, "'" # clip(ph, 40) # "' has fewer than 7 digits — not a phone number.") };
      case (null) {};
    };

    let tags : [Text] = if (hasField(clearList, "tags")) [] else switch (readTextList(args, "tags")) {
      case (?raw) switch (normalizeTags(raw)) { case (#ok(t)) t; case (#err(e)) return fail(cb, e) };
      case (null) switch (existing) { case (?c) c.tags; case (null) [] };
    };

    let allowDup = switch (optBool(args, "allow_duplicate")) { case (?b) b; case (null) false };
    if (not allowDup) {
      // On update, only re-check identity fields the caller actually changed.
      let changedName = switch (existing) { case (?c) (c.name != name or c.company != company); case (null) true };
      let dups = duplicatesOf(
        p,
        switch (existing) { case (?c) ?c.id; case (null) null },
        if (changedName) ?name else null,
        company,
        switch (existing) { case (?c) { if (c.email == email) null else email }; case (null) email },
        switch (existing) { case (?c) { if (c.phone == phone) null else phone }; case (null) phone },
      );
      if (dups.size() > 0) {
        return cb(#ok({
          content = [#text({ text = "Looks like a contact you already have. Update that one (contact_id), merge_contacts later, or pass allow_duplicate=true if this really is someone else. Matches: " # Json.stringify(Json.arr(dups), null) })];
          isError = true;
          structuredContent = ?Json.obj([("duplicates", Json.arr(dups))]);
        }));
      };
    };

    switch (existing) {
      case (?c) {
        let updated = { c with name = name; company = company; email = email; phone = phone; address = address; source = source; notes = notes; tags = tags; updatedAt = now };
        putContact(updated);
        cb(#ok(okResult(Json.obj([
          ("message", Json.str("Contact updated.")),
          ("contact", contactSummaryJson(updated, book, now)),
        ]))));
      };
      case (null) {
        switch (contactCapProblem(p)) { case (?e) return fail(cb, e); case (null) {} };
        let stage = switch (optText(args, "stage")) {
          case (null) #lead;
          case (?t) switch (parseStage(t)) {
            case (?#lead) #lead;
            case (?#qualified) #qualified;
            case (?#customer) #customer;
            case (_) return fail(cb, "A new contact starts as lead, qualified, or customer.");
          };
        };
        let fresh = blankContact(p, name, stage, now);
        let c = { fresh with company = company; email = email; phone = phone; address = address; source = source; notes = notes; tags = tags };
        insertContact(c);
        cb(#ok(okResult(Json.obj([
          ("message", Json.str("Contact added as " # stageText(stage) # ". Log conversations with log_activity; schedule_follow_up keeps it off the stale list.")),
          ("contact", contactSummaryJson(c, book, now)),
        ]))));
      };
    };
  };

  // --- find_contacts ---

  func sortByRecency(cs : [Contact]) : [Contact] {
    func recency(c : Contact) : Int { switch (c.lastTouchAt) { case (?t) t; case (null) c.createdAt } };
    Array.sort<Contact>(cs, func(a, b) { Int.compare(recency(b), recency(a)) });
  };

  func findContactsTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let now = Time.now();
    let needle = switch (optText(args, "query")) { case (?q) ?lower(q); case (null) null };
    let queryDigits = switch (optText(args, "query")) { case (?q) phoneDigits(q); case (null) "" };
    let stageFilter = switch (optText(args, "stage")) {
      case (null) "default";
      case (?t) {
        let v = lower(t);
        if (v != "open" and v != "all" and parseStage(v) == null) return fail(cb, "'stage' must be lead, qualified, customer, lost, archived, open, or all.");
        v;
      };
    };
    let tag = switch (optText(args, "tag")) { case (?t) ?lower(t); case (null) null };
    let source = switch (optText(args, "source")) { case (?s) ?lower(s); case (null) null };
    let staleOnly = switch (optBool(args, "stale_only")) { case (?b) b; case (null) false };
    let limit = Nat.min(switch (optNat(args, "limit")) { case (?n) Nat.max(n, 1); case (null) 25 }, maxListResults);

    let hits = Buffer.Buffer<Contact>(32);
    for (c in bookContacts(p).vals()) {
      let stageOk = switch (stageFilter) {
        case ("default") c.stage != #archived;
        case ("all") true;
        case ("open") isOpenStage(c.stage);
        case (s) stageText(c.stage) == s;
      };
      let queryOk = switch (needle) {
        case (null) true;
        case (?q) {
          contains(c.name, q) or optContains(c.company, q) or optContains(c.email, q) or optContains(c.source, q)
          or (queryDigits.size() >= 4 and (switch (c.phone) { case (?ph) Text.contains(phoneDigits(ph), #text queryDigits); case (null) false }))
          or Array.find<Text>(c.tags, func(t) { Text.contains(t, #text q) }) != null;
        };
      };
      let tagOk = switch (tag) { case (?t) Array.find<Text>(c.tags, func(x) { x == t }) != null; case (null) true };
      let sourceOk = switch (source) { case (?s) (switch (c.source) { case (?cs) lower(cs) == s; case (null) false }); case (null) true };
      if (stageOk and queryOk and tagOk and sourceOk and (not staleOnly or isStale(c, book, now))) hits.add(c);
    };
    let sorted = sortByRecency(Buffer.toArray(hits));
    let shown = if (sorted.size() > limit) Array.subArray(sorted, 0, limit) else sorted;
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(if (sorted.size() == 0) "No contacts match." else Nat.toText(sorted.size()) # " match; most recently touched first.")),
      ("total_matches", Json.int(sorted.size())),
      ("contacts", Json.arr(Array.map<Contact, Json.Json>(shown, func(c) { contactSummaryJson(c, book, now) }))),
    ]))));
  };

  // --- get_contact ---

  func getContactTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let ?id = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required.");
    let tz = book.tzOffsetMinutes;
    let now = Time.now();

    // Tombstones are readable (so an old id still explains itself) but not editable.
    let ?c = getContact(id) else return fail(cb, "No contact with id " # Nat.toText(id) # " in your book.");
    if (c.owner != p) return fail(cb, "No contact with id " # Nat.toText(id) # " in your book.");
    switch (c.mergedInto) {
      case (?k) return cb(#ok(okResult(Json.obj([
        ("message", Json.str("Contact " # Nat.toText(id) # " was merged into contact " # Nat.toText(k) # ".")),
        ("merged_into", Json.int(k)),
      ]))));
      case (null) {};
    };
    switch (c.erasedAt) {
      case (?t) return cb(#ok(okResult(Json.obj([
        ("message", Json.str("Contact " # Nat.toText(id) # " was erased on " # fmtLocal(t, tz) # ". Dates, stages, and deal values remain in your pipeline; nothing identifying does.")),
        ("stage", Json.str(stageText(c.stage))),
      ]))));
      case (null) {};
    };

    let limit = Nat.min(switch (optNat(args, "timeline_limit")) { case (?n) n; case (null) 30 }, 100);
    let acts = Array.sort<Activity>(contactActivities(c.id), func(a, b) { Int.compare(b.at, a.at) });
    let shownActs = if (acts.size() > limit) Array.subArray(acts, 0, limit) else acts;
    let fus = Array.sort<FollowUp>(contactFollowUps(c.id), func(a, b) { Int.compare(a.dueAt, b.dueAt) });
    let openFus = Array.filter<FollowUp>(fus, func(f) { f.status == #open });
    let pastFus = Array.filter<FollowUp>(fus, func(f) { f.status != #open });
    let deals = contactDeals(c.id);
    let inquiries = contactInquiries(c.id);
    let (touch, ago) = touchJson(c, tz, now);
    let lastWon = Array.find<Deal>(Array.sort<Deal>(deals, func(a, b) { Int.compare(b.stageChangedAt, a.stageChangedAt) }), func(d) { d.stage == #won });

    cb(#ok(okResult(Json.obj([
      ("contact_id", Json.int(c.id)),
      ("name", Json.str(c.name)),
      ("company", optJsonText(c.company)),
      ("stage", Json.str(stageText(c.stage))),
      ("stage_reason", optJsonText(c.stageReason)),
      ("email", optJsonText(c.email)),
      ("phone", optJsonText(c.phone)),
      ("address", optJsonText(c.address)),
      ("source", optJsonText(c.source)),
      ("tags", tagsJson(c.tags)),
      ("notes", optJsonText(c.notes)),
      ("agent_principal", switch (c.agent) { case (?a) Json.str(Principal.toText(a)); case (null) Json.nullable() }),
      ("added", Json.str(fmtLocal(c.createdAt, tz))),
      ("last_touch", touch),
      ("last_touch_ago", ago),
      ("stale", Json.bool(isStale(c, book, now))),
      ("open_follow_ups", Json.arr(Array.map<FollowUp, Json.Json>(openFus, func(f) { followUpJson(f, tz, now) }))),
      ("deals", Json.arr(Array.map<Deal, Json.Json>(deals, func(d) { dealJson(d, tz, false) }))),
      ("inquiries", Json.arr(Array.map<Inquiry, Json.Json>(inquiries, func(q) { inquiryOwnerJson(q, tz, now) }))),
      ("timeline", Json.arr(Array.map<Activity, Json.Json>(shownActs, func(a) { activityJson(a, tz) }))),
      ("timeline_total", Json.int(acts.size())),
      ("past_follow_ups", Json.arr(Array.map<FollowUp, Json.Json>(pastFus, func(f) { followUpJson(f, tz, now) }))),
      ("history", eventsJson(c.events, tz)),
      ("handoff", handoffJson(c, lastWon)),
    ]))));
  };

  // --- set_stage ---

  func setStageTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let ?id = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required.");
    let ?c = ownedContact(p, id, cb) else return;
    let ?stageArg = optText(args, "stage") else return fail(cb, "'stage' is required: lead, qualified, customer, lost, or archived.");
    let ?stage = parseStage(stageArg) else return fail(cb, "'" # stageArg # "' is not a stage. Use lead, qualified, customer, lost, or archived.");
    let reason = switch (optLen(args, "reason", maxFieldChars)) { case (#ok(r)) ?r; case (#err(e)) return fail(cb, e); case (#absent) null };
    if (stage == #lost and reason == null) return fail(cb, "A reason is required to mark a contact lost — it is what makes the loss useful later, e.g. 'Went with a cheaper quote'.");
    if (stage == c.stage) return fail(cb, c.name # " is already " # stageText(stage) # ".");
    let now = Time.now();
    let event = "Stage " # stageText(c.stage) # " → " # stageText(stage) # (switch (reason) { case (?r) ": " # r; case (null) "." });
    let updated = { c with stage = stage; stageReason = reason; events = pushEvent(c.events, event, now); updatedAt = now };
    putContact(updated);
    cb(#ok(okResult(Json.obj([("message", Json.str(event)), ("contact", contactSummaryJson(updated, book, now))]))));
  };

  // --- log_activity ---

  /// Parse next_follow_up/next_task. #none when neither is given.
  func nextStep(args : McpTypes.JsonValue, tz : Int, now : Int, cb : ToolCb) : { #none; #ok : (Int, Text); #failed } {
    switch (optText(args, "next_follow_up")) {
      case (null) {
        if (optText(args, "next_task") != null) { fail(cb, "'next_task' needs 'next_follow_up' — when should it happen?"); return #failed };
        #none;
      };
      case (?dueText) {
        let ?due = parseDue(dueText, tz, now) else { fail(cb, "'" # dueText # "' is not a time I understand. " # dueHelp); return #failed };
        if (due < now - 5 * nanosPerMinute) { fail(cb, "'next_follow_up' is in the past (" # fmtLocal(due, tz) # ")."); return #failed };
        let task = switch (optLen(args, "next_task", maxFieldChars)) {
          case (#ok(t)) t;
          case (#err(e)) { fail(cb, e); return #failed };
          case (#absent) { fail(cb, "'next_task' is required with 'next_follow_up' — what is the next step?"); return #failed };
        };
        #ok((due, task));
      };
    };
  };

  func logActivityTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let ?id = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required.");
    let ?c = ownedContact(p, id, cb) else return;
    let ?kindArg = optText(args, "kind") else return fail(cb, "'kind' is required: call, email, text, meeting, visit, or note.");
    let ?kind = parseKind(kindArg) else return fail(cb, "'" # kindArg # "' is not an activity kind. Use call, email, text, meeting, visit, or note.");
    let ?summary = optText(args, "summary") else return fail(cb, "'summary' is required — what happened.");
    switch (requireLen(summary, "summary", 1, maxTextChars)) { case (?e) return fail(cb, e); case (null) {} };
    let direction = switch (optText(args, "direction")) {
      case (?d) switch (parseDirection(d)) { case (?v) v; case (null) return fail(cb, "'direction' must be inbound, outbound, or internal.") };
      case (null) if (kind == #note) #internal else #outbound;
    };
    let now = Time.now();
    let at = switch (optText(args, "at")) {
      case (?t) switch (parseLocalStamp(t, tz)) {
        case (?v) v;
        case (null) return fail(cb, "'at' must be 'YYYY-MM-DD HH:MM' in your local time.");
      };
      case (null) now;
    };
    if (at > now + 5 * nanosPerMinute) return fail(cb, "'at' is in the future. Log it once it happens, or schedule_follow_up for it.");
    let dealId = switch (dealOnContact(p, args, c.id, cb)) { case (#none) null; case (#ok(d)) ?d; case (#failed) return };
    let completes : ?FollowUp = switch (optNat(args, "completes_follow_up_id")) {
      case (null) null;
      case (?fid) {
        let ?f = ownedFollowUp(p, fid, cb) else return;
        if (f.contactId != c.id) return fail(cb, "Follow-up " # Nat.toText(fid) # " is on contact " # Nat.toText(f.contactId) # ", not " # Nat.toText(c.id) # ".");
        if (f.status != #open) return fail(cb, "Follow-up " # Nat.toText(fid) # " is already " # followStatusText(f.status) # ".");
        ?f;
      };
    };
    let next = switch (nextStep(args, tz, now, cb)) { case (#none) null; case (#ok(v)) ?v; case (#failed) return };
    switch (activityCapProblem(p, c.id)) { case (?e) return fail(cb, e); case (null) {} };
    switch (next) {
      case (?_) {
        // Completing one frees a slot for the next.
        let freed = if (completes != null) 1 else 0;
        if (openFollowUpCount(c.id) >= maxOpenFollowUpsPerContact + freed) return fail(cb, "Contact already has " # Nat.toText(maxOpenFollowUpsPerContact) # " open follow-ups.");
        if (idsOf(followUpIdsByOwner, p).size() >= maxFollowUpsPerBook) return fail(cb, "This book has reached " # Nat.toText(maxFollowUpsPerBook) # " follow-ups.");
      };
      case (null) {};
    };

    let (a, updated) = recordActivity(p, c, dealId, kind, direction, summary, at, now);
    let closed = switch (completes) {
      case (?f) {
        let done = { f with status = #done; outcome = ?summary; closedAt = ?now };
        putFollowUp(done);
        ?done;
      };
      case (null) null;
    };
    let scheduled = switch (next) {
      case (?(due, task)) ?insertFollowUp(p, c.id, dealId, task, due, now);
      case (null) null;
    };

    var msg = "Logged " # kindText(kind) # " with " # c.name # ".";
    if (closed != null) msg #= " Follow-up marked done.";
    switch (scheduled) { case (?f) msg #= " Next step scheduled for " # fmtLocal(f.dueAt, tz) # "."; case (null) {} };
    if (kind == #note) msg #= " (Notes do not count as a touch.)";
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(msg)),
      ("activity", activityJson(a, tz)),
      ("completed_follow_up", switch (closed) { case (?f) followUpJson(f, tz, now); case (null) Json.nullable() }),
      ("next_follow_up", switch (scheduled) { case (?f) followUpJson(f, tz, now); case (null) Json.nullable() }),
      ("contact", contactSummaryJson(updated, book, now)),
    ]))));
  };

  // --- schedule_follow_up ---

  func scheduleFollowUpTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let ?id = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required.");
    let ?c = ownedContact(p, id, cb) else return;
    let ?dueText = optText(args, "due") else return fail(cb, "'due' is required. " # dueHelp);
    let now = Time.now();
    let ?due = parseDue(dueText, tz, now) else return fail(cb, "'" # dueText # "' is not a time I understand. " # dueHelp);
    if (due < now - 5 * nanosPerMinute) return fail(cb, "That is in the past (" # fmtLocal(due, tz) # "). Pick a future time.");
    let ?task = optText(args, "task") else return fail(cb, "'task' is required — what should happen.");
    switch (requireLen(task, "task", 1, maxFieldChars)) { case (?e) return fail(cb, e); case (null) {} };
    let dealId = switch (dealOnContact(p, args, c.id, cb)) { case (#none) null; case (#ok(d)) ?d; case (#failed) return };
    switch (followUpCapProblem(p, c.id)) { case (?e) return fail(cb, e); case (null) {} };
    let f = insertFollowUp(p, c.id, dealId, task, due, now);
    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Scheduled for " # fmtLocal(due, tz) # " (" # fmtAgo(now, due) # ").")),
      ("follow_up", followUpJson(f, tz, now)),
    ]))));
  };

  // --- complete_follow_up ---

  func completeFollowUpTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let ?fid = optNat(args, "follow_up_id") else return fail(cb, "'follow_up_id' is required.");
    let ?f = ownedFollowUp(p, fid, cb) else return;
    if (f.status != #open) return fail(cb, "Follow-up " # Nat.toText(fid) # " is already " # followStatusText(f.status) # ".");
    let ?c = ownedContact(p, f.contactId, cb) else return;
    let cancel = switch (optBool(args, "cancel")) { case (?b) b; case (null) false };
    let outcome = switch (optLen(args, "outcome", maxTextChars)) {
      case (#ok(o)) ?o;
      case (#err(e)) return fail(cb, e);
      case (#absent) {
        if (not cancel) return fail(cb, "'outcome' is required — what came of it? (Or cancel=true.)");
        null;
      };
    };
    let logAs : ?ActivityKind = switch (optText(args, "log_as")) {
      case (null) null;
      case (?t) {
        if (cancel) return fail(cb, "'log_as' records an interaction; a cancelled follow-up had none.");
        switch (parseKind(t)) {
          case (?#note) return fail(cb, "'log_as' must be call, email, text, meeting, or visit.");
          case (?k) ?k;
          case (null) return fail(cb, "'log_as' must be call, email, text, meeting, or visit.");
        };
      };
    };
    let now = Time.now();
    let next = switch (nextStep(args, tz, now, cb)) { case (#none) null; case (#ok(v)) ?v; case (#failed) return };
    if (logAs != null) {
      switch (activityCapProblem(p, c.id)) { case (?e) return fail(cb, e); case (null) {} };
    };
    if (next != null and idsOf(followUpIdsByOwner, p).size() >= maxFollowUpsPerBook) {
      return fail(cb, "This book has reached " # Nat.toText(maxFollowUpsPerBook) # " follow-ups.");
    };

    let closed = { f with status = if (cancel) #cancelled else #done; outcome = outcome; closedAt = ?now };
    putFollowUp(closed);
    var contact = c;
    switch (logAs, outcome) {
      case (?k, ?o) {
        let (_, updated) = recordActivity(p, c, f.dealId, k, #outbound, f.task # " — " # o, now, now);
        contact := updated;
      };
      case (_, _) {};
    };
    let scheduled = switch (next) {
      case (?(due, task)) ?insertFollowUp(p, c.id, f.dealId, task, due, now);
      case (null) null;
    };
    var msg = if (cancel) "Follow-up cancelled." else "Follow-up done.";
    if (logAs != null) msg #= " Logged on the timeline as a touch.";
    switch (scheduled) { case (?s) msg #= " Next step scheduled for " # fmtLocal(s.dueAt, tz) # "."; case (null) {} };
    if (scheduled == null and isOpenStage(contact.stage) and openFollowUpCount(c.id) == 0) {
      msg #= " " # contact.name # " has nothing else scheduled.";
    };
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(msg)),
      ("follow_up", followUpJson(closed, tz, now)),
      ("next_follow_up", switch (scheduled) { case (?s) followUpJson(s, tz, now); case (null) Json.nullable() }),
    ]))));
  };

  // --- get_agenda ---

  func getAgendaTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let days = Nat.min(switch (optNat(args, "days")) { case (?d) Nat.max(d, 1); case (null) 7 }, 30);
    let now = Time.now();
    let (today, _) = toLocal(now, tz);
    let endOfToday = fromLocal(today + 1, 0, tz);
    let horizon = fromLocal(today + 1 + days, 0, tz);

    let overdue = Buffer.Buffer<FollowUp>(8);
    let dueToday = Buffer.Buffer<FollowUp>(8);
    let upcoming = Buffer.Buffer<FollowUp>(8);
    for (id in idsOf(followUpIdsByOwner, p).vals()) {
      switch (getFollowUp(id)) {
        case (?f) {
          let live = switch (resolveLive(f.contactId)) { case (?_) true; case (null) false };
          if (f.status == #open and live) {
            if (f.dueAt < now) overdue.add(f) else if (f.dueAt < endOfToday) dueToday.add(f) else if (f.dueAt < horizon) upcoming.add(f);
          };
        };
        case (null) {};
      };
    };
    func byDue(fs : Buffer.Buffer<FollowUp>) : [Json.Json] {
      let sorted = Array.sort<FollowUp>(Buffer.toArray(fs), func(a, b) { Int.compare(a.dueAt, b.dueAt) });
      let capped = if (sorted.size() > maxListResults) Array.subArray(sorted, 0, maxListResults) else sorted;
      Array.map<FollowUp, Json.Json>(capped, func(f) { followUpJson(f, tz, now) });
    };

    let waiting = Buffer.Buffer<Inquiry>(8);
    for (id in idsOf(inquiryIdsByBusiness, p).vals()) {
      switch (getInquiry(id)) { case (?q) { if (q.status == #open and not q.erased) waiting.add(q) }; case (null) {} };
    };

    let stale = Buffer.Buffer<Contact>(8);
    for (c in bookContacts(p).vals()) { if (isStale(c, book, now)) stale.add(c) };
    let staleSorted = Array.sort<Contact>(Buffer.toArray(stale), func(a, b) {
      let ta = switch (a.lastTouchAt) { case (?t) t; case (null) a.createdAt };
      let tb = switch (b.lastTouchAt) { case (?t) t; case (null) b.createdAt };
      Int.compare(ta, tb);
    });

    let pastClose = Buffer.Buffer<Deal>(8);
    for (d in bookDeals(p).vals()) {
      switch (d.expectedCloseDay) {
        case (?day) { if (not isClosedDeal(d.stage) and day < today) pastClose.add(d) };
        case (null) {};
      };
    };

    let parts = Buffer.Buffer<Text>(5);
    if (overdue.size() > 0) parts.add(Nat.toText(overdue.size()) # " overdue");
    if (dueToday.size() > 0) parts.add(Nat.toText(dueToday.size()) # " due today");
    if (waiting.size() > 0) parts.add(Nat.toText(waiting.size()) # " inquir" # (if (waiting.size() == 1) "y" else "ies") # " waiting");
    if (stale.size() > 0) parts.add(Nat.toText(stale.size()) # " stale lead" # (if (stale.size() == 1) "" else "s"));
    if (pastClose.size() > 0) parts.add(Nat.toText(pastClose.size()) # " deal" # (if (pastClose.size() == 1) "" else "s") # " past expected close");
    let message = if (parts.size() == 0) "Nothing needs you right now." else Text.join(", ", parts.vals()) # ".";

    let staleShown = if (staleSorted.size() > maxListResults) Array.subArray(staleSorted, 0, maxListResults) else staleSorted;
    let waitingArr = Buffer.toArray(waiting);
    let waitingShown = if (waitingArr.size() > maxListResults) Array.subArray(waitingArr, 0, maxListResults) else waitingArr;
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(message)),
      ("local_time_now", Json.str(fmtLocal(now, tz))),
      ("overdue", Json.arr(byDue(overdue))),
      ("today", Json.arr(byDue(dueToday))),
      ("upcoming", Json.arr(byDue(upcoming))),
      ("upcoming_days", Json.int(days)),
      ("inquiries_waiting", Json.arr(Array.map<Inquiry, Json.Json>(waitingShown, func(q) { inquiryOwnerJson(q, tz, now) }))),
      ("stale_leads", Json.arr(Array.map<Contact, Json.Json>(staleShown, func(c) { contactSummaryJson(c, book, now) }))),
      ("deals_past_expected_close", Json.arr(Array.map<Deal, Json.Json>(Buffer.toArray(pastClose), func(d) { dealJson(d, tz, false) }))),
    ]))));
  };

  // --- add_deal ---

  func addDealTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let now = Time.now();
    let (today, _) = toLocal(now, tz);

    let value : ?Nat = switch (optPriceCents(args, "value_usd")) {
      case (?v) { if (v > 100_000_000_00) return fail(cb, "'value_usd' is over $100M — check the number."); ?v };
      case (null) null;
    };
    let close : ?Int = switch (optText(args, "expected_close")) {
      case (?t) switch (parseDayArg(t, today)) {
        case (?d) ?d;
        case (null) return fail(cb, "'expected_close' must be 'YYYY-MM-DD', 'today', 'tomorrow', or '+N' days.");
      };
      case (null) null;
    };
    let title = switch (optLen(args, "title", maxNameChars)) { case (#ok(t)) ?t; case (#err(e)) return fail(cb, e); case (#absent) null };

    switch (optNat(args, "deal_id")) {
      case (?id) {
        let ?d = ownedDeal(p, id, cb) else return;
        let clearValue = switch (optBool(args, "clear_value")) { case (?b) b; case (null) false };
        let clearClose = switch (optBool(args, "clear_expected_close")) { case (?b) b; case (null) false };
        if (optText(args, "stage") != null) return fail(cb, "Use move_deal to change a deal's stage.");
        let newValue = if (clearValue) null else switch (value) { case (?v) ?v; case (null) d.valueCents };
        let newClose = if (clearClose) null else switch (close) { case (?c) ?c; case (null) d.expectedCloseDay };
        let newTitle = switch (title) { case (?t) t; case (null) d.title };
        var events = d.events;
        if (newValue != d.valueCents) {
          let show = func(v : ?Nat) : Text { switch (v) { case (?c) usdText(c); case (null) "none" } };
          events := pushEvent(events, "Value " # show(d.valueCents) # " → " # show(newValue) # ".", now);
        };
        if (newClose != d.expectedCloseDay) {
          let show = func(v : ?Int) : Text { switch (v) { case (?c) fmtDate(c); case (null) "none" } };
          events := pushEvent(events, "Expected close " # show(d.expectedCloseDay) # " → " # show(newClose) # ".", now);
        };
        if (newTitle != d.title) events := pushEvent(events, "Renamed from '" # d.title # "'.", now);
        let updated = { d with title = newTitle; valueCents = newValue; expectedCloseDay = newClose; events = events };
        putDeal(updated);
        cb(#ok(okResult(Json.obj([("message", Json.str("Deal updated.")), ("deal", dealJson(updated, tz, true))]))));
      };
      case (null) {
        let ?cid = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required to open a deal (or pass deal_id to update one).");
        let ?c = ownedContact(p, cid, cb) else return;
        let ?t = title else return fail(cb, "'title' is required — what the deal is, e.g. 'Double door + opener install'.");
        let stage : DealStage = switch (optText(args, "stage")) {
          case (null) #new;
          case (?s) switch (parseDealStage(s)) {
            case (?#won) return fail(cb, "Open the deal first, then move_deal to won — that is what records the close.");
            case (?#lost) return fail(cb, "A deal cannot open as lost.");
            case (?v) v;
            case (null) return fail(cb, "'stage' must be new, contacted, quoted, or negotiating.");
          };
        };
        if (idsOf(dealIdsByOwner, p).size() >= maxDealsPerBook) return fail(cb, "This book has reached " # Nat.toText(maxDealsPerBook) # " deals.");
        let d : Deal = {
          id = nextDealId;
          owner = p;
          contactId = c.id;
          title = t;
          valueCents = value;
          stage = stage;
          expectedCloseDay = close;
          lostReason = null;
          closedAt = null;
          events = [{ at = now; event = "Opened as " # dealStageText(stage) # (switch (value) { case (?v) " at " # usdText(v); case (null) "" }) # "." }];
          createdAt = now;
          stageChangedAt = now;
        };
        nextDealId += 1;
        putDeal(d);
        indexAdd(dealIdsByOwner, p, d.id);
        indexAddN(dealIdsByContact, c.id, d.id);
        var msg = "Deal opened.";
        if (c.stage == #lead) {
          putContact({ c with stage = #qualified; stageReason = null; events = pushEvent(c.events, "Stage lead → qualified: deal #" # Nat.toText(d.id) # " opened.", now); updatedAt = now });
          msg #= " " # c.name # " moved from lead to qualified.";
        };
        cb(#ok(okResult(Json.obj([("message", Json.str(msg)), ("deal", dealJson(d, tz, true))]))));
      };
    };
  };

  // --- move_deal ---

  func moveDealTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let tz = book.tzOffsetMinutes;
    let ?id = optNat(args, "deal_id") else return fail(cb, "'deal_id' is required.");
    let ?d = ownedDeal(p, id, cb) else return;
    let ?stageArg = optText(args, "stage") else return fail(cb, "'stage' is required: new, contacted, quoted, negotiating, won, or lost.");
    let ?stage = parseDealStage(stageArg) else return fail(cb, "'" # stageArg # "' is not a deal stage. Use new, contacted, quoted, negotiating, won, or lost.");
    if (stage == d.stage) return fail(cb, "Deal " # Nat.toText(id) # " is already " # dealStageText(stage) # ".");
    let reason = switch (optLen(args, "reason", maxFieldChars)) { case (#ok(r)) ?r; case (#err(e)) return fail(cb, e); case (#absent) null };
    if (stage == #lost and reason == null) return fail(cb, "A reason is required to mark a deal lost, e.g. 'Price — went with a competitor'.");
    let now = Time.now();

    let reopening = isClosedDeal(d.stage) and not isClosedDeal(stage);
    let event = (if (reopening) "Reopened: " else "") # dealStageText(d.stage) # " → " # dealStageText(stage) # (switch (reason) { case (?r) ": " # r; case (null) "." });
    let updated = {
      d with
      stage = stage;
      stageChangedAt = now;
      closedAt = if (isClosedDeal(stage)) ?now else null;
      lostReason = if (stage == #lost) reason else null;
      events = pushEvent(d.events, event, now);
    };
    putDeal(updated);

    var msg = "Deal " # Nat.toText(id) # ": " # event;
    let contact = getContact(d.contactId);
    var handoff = Json.nullable();
    if (stage == #won) {
      switch (contact) {
        case (?c) {
          if (isLive(c)) {
            if (c.stage != #customer) {
              putContact({ c with stage = #customer; stageReason = null; events = pushEvent(c.events, "Stage " # stageText(c.stage) # " → customer: deal #" # Nat.toText(id) # " won.", now); updatedAt = now });
              msg #= " " # c.name # " is now a customer.";
            };
            handoff := handoffJson(c, ?updated);
            msg #= " Hand-off arguments for Dispatch Scheduler and Invoice Desk are below.";
          };
        };
        case (null) {};
      };
    };
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(msg)),
      ("deal", dealJson(updated, tz, true)),
      ("handoff", handoff),
    ]))));
  };

  // --- get_pipeline ---

  func getPipelineTool(_args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?_book = requireBook(p, cb) else return;
    let now = Time.now();
    let deals = bookDeals(p);

    let stageRows = Buffer.Buffer<Json.Json>(4);
    var openCount = 0;
    var openValue = 0;
    for (s in openDealStages.vals()) {
      var n = 0;
      var v = 0;
      for (d in deals.vals()) {
        if (d.stage == s) {
          n += 1;
          switch (d.valueCents) { case (?c) v += c; case (null) {} };
        };
      };
      openCount += n;
      openValue += v;
      stageRows.add(Json.obj([("stage", Json.str(dealStageText(s))), ("deals", Json.int(n)), ("value_usd", usdFloat(v))]));
    };

    var won = 0;
    var wonValue = 0;
    var lost = 0;
    var lostValue = 0;
    var closeNanos : Int = 0;
    var won30Value = 0;
    var won30 = 0;
    for (d in deals.vals()) {
      let v = switch (d.valueCents) { case (?c) c; case (null) 0 };
      if (d.stage == #won) {
        won += 1;
        wonValue += v;
        switch (d.closedAt) {
          case (?t) {
            closeNanos += t - d.createdAt;
            if (now - t <= 30 * nanosPerDay) { won30 += 1; won30Value += v };
          };
          case (null) {};
        };
      } else if (d.stage == #lost) {
        lost += 1;
        lostValue += v;
      };
    };
    let avgDays : Json.Json = if (won == 0) Json.nullable() else Json.float(Float.fromInt(closeNanos / won) / Float.fromInt(nanosPerDay));

    // Contacts by stage, and how each source converts to customers.
    let contacts = bookContacts(p);
    let stages : [Stage] = [#lead, #qualified, #customer, #lost, #archived];
    let byStage = Array.map<Stage, (Text, Json.Json)>(stages, func(s) {
      var n = 0;
      for (c in contacts.vals()) { if (c.stage == s) n += 1 };
      (stageText(s), Json.int(n));
    });
    let sources = Buffer.Buffer<Text>(8);
    for (c in contacts.vals()) {
      let s = switch (c.source) { case (?x) lower(x); case (null) "(none)" };
      if (not Buffer.contains<Text>(sources, s, Text.equal)) sources.add(s);
    };
    let sourceRows = Buffer.Buffer<(Nat, Json.Json)>(sources.size());
    for (s in sources.vals()) {
      var total = 0;
      var customers = 0;
      for (c in contacts.vals()) {
        let cs = switch (c.source) { case (?x) lower(x); case (null) "(none)" };
        if (cs == s) {
          total += 1;
          if (c.stage == #customer) customers += 1;
        };
      };
      sourceRows.add((total, Json.obj([("source", Json.str(s)), ("contacts", Json.int(total)), ("customers", Json.int(customers)), ("conversion_pct", pct(customers, total))])));
    };
    let sourcesSorted = Array.sort<(Nat, Json.Json)>(Buffer.toArray(sourceRows), func(a, b) { Nat.compare(b.0, a.0) });

    let message = if (deals.size() == 0) "No deals yet. add_deal opens one on a contact." else Nat.toText(openCount) # " open deals worth " # usdText(openValue) # "; " # Nat.toText(won) # " won, " # Nat.toText(lost) # " lost.";
    cb(#ok(okResult(Json.obj([
      ("message", Json.str(message)),
      ("open_by_stage", Json.arr(Buffer.toArray(stageRows))),
      ("open_deals", Json.int(openCount)),
      ("open_value_usd", usdFloat(openValue)),
      ("won", Json.obj([("deals", Json.int(won)), ("value_usd", usdFloat(wonValue))])),
      ("lost", Json.obj([("deals", Json.int(lost)), ("value_usd", usdFloat(lostValue))])),
      ("win_rate_pct", pct(won, won + lost)),
      ("avg_days_to_close", avgDays),
      ("won_last_30_days", Json.obj([("deals", Json.int(won30)), ("value_usd", usdFloat(won30Value))])),
      ("contacts_by_stage", Json.obj(byStage)),
      ("conversion_by_source", Json.arr(Array.map<(Nat, Json.Json), Json.Json>(sourcesSorted, func(r) { r.1 }))),
    ]))));
  };

  // --- merge_contacts ---

  func mergeContactsTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let ?keepId = optNat(args, "keep_id") else return fail(cb, "'keep_id' is required — the contact that survives.");
    let ?mergeId = optNat(args, "merge_id") else return fail(cb, "'merge_id' is required — the duplicate to fold in.");
    if (keepId == mergeId) return fail(cb, "keep_id and merge_id are the same contact.");
    let ?keep = ownedContact(p, keepId, cb) else return;
    let ?dup = ownedContact(p, mergeId, cb) else return;
    let now = Time.now();

    let keepActs = idsOfN(activityIdsByContact, keep.id);
    let dupActs = idsOfN(activityIdsByContact, dup.id);
    if (keepActs.size() + dupActs.size() > maxActivitiesPerContact) {
      return fail(cb, "Together these contacts have more than " # Nat.toText(maxActivitiesPerContact) # " activities; they cannot be merged.");
    };

    // Re-point every record, then splice the indexes.
    for (id in dupActs.vals()) {
      switch (getActivity(id)) { case (?a) Map.set(activitiesById, nhash, id, { a with contactId = keep.id }); case (null) {} };
    };
    Map.set(activityIdsByContact, nhash, keep.id, Array.append(keepActs, dupActs));
    Map.delete(activityIdsByContact, nhash, dup.id);
    for (id in idsOfN(followUpIdsByContact, dup.id).vals()) {
      switch (getFollowUp(id)) { case (?f) putFollowUp({ f with contactId = keep.id }); case (null) {} };
    };
    Map.set(followUpIdsByContact, nhash, keep.id, Array.append(idsOfN(followUpIdsByContact, keep.id), idsOfN(followUpIdsByContact, dup.id)));
    Map.delete(followUpIdsByContact, nhash, dup.id);
    for (id in idsOfN(dealIdsByContact, dup.id).vals()) {
      switch (getDeal(id)) { case (?d) putDeal({ d with contactId = keep.id }); case (null) {} };
    };
    Map.set(dealIdsByContact, nhash, keep.id, Array.append(idsOfN(dealIdsByContact, keep.id), idsOfN(dealIdsByContact, dup.id)));
    Map.delete(dealIdsByContact, nhash, dup.id);
    for (id in idsOfN(inquiryIdsByContact, dup.id).vals()) {
      switch (getInquiry(id)) { case (?q) putInquiry({ q with contactId = keep.id }); case (null) {} };
    };
    Map.set(inquiryIdsByContact, nhash, keep.id, Array.append(idsOfN(inquiryIdsByContact, keep.id), idsOfN(inquiryIdsByContact, dup.id)));
    Map.delete(inquiryIdsByContact, nhash, dup.id);

    // Future inquiries from the duplicate's principal land on the survivor.
    switch (dup.agent) {
      case (?a) Map.set(contactByAgent, thash, Principal.toText(p) # "#" # Principal.toText(a), keep.id);
      case (null) {};
    };

    // Fill blanks; keep differing contact details in notes rather than drop them.
    let kept = Buffer.Buffer<Text>(3);
    func pick(k : ?Text, d : ?Text, label_ : Text) : ?Text {
      switch (k, d) {
        case (null, dv) dv;
        case (?kv, ?dv) { if (lower(kv) != lower(dv)) kept.add(label_ # " " # dv); ?kv };
        case (?kv, null) ?kv;
      };
    };
    let email = pick(keep.email, dup.email, "email");
    let phone = pick(keep.phone, dup.phone, "phone");
    let address = pick(keep.address, dup.address, "address");
    let company = pick(keep.company, dup.company, "company");
    let source = switch (keep.source) { case (?s) ?s; case (null) dup.source };
    var notes = switch (keep.notes, dup.notes) {
      case (?a, ?b) ?(a # "\n" # b);
      case (?a, null) ?a;
      case (null, b) b;
    };
    if (kept.size() > 0) {
      let line = "Merged from #" # Nat.toText(dup.id) # " (" # dup.name # "): " # Text.join("; ", kept.vals());
      notes := switch (notes) { case (?n) ?(n # "\n" # line); case (null) ?line };
    };
    switch (notes) { case (?n) { if (n.size() > maxTextChars * 2) notes := ?clip(n, maxTextChars * 2) }; case (null) {} };
    let tagBuf = Buffer.fromArray<Text>(keep.tags);
    for (t in dup.tags.vals()) { if (not Buffer.contains<Text>(tagBuf, t, Text.equal)) tagBuf.add(t) };
    let tags = if (tagBuf.size() > maxTags) Array.subArray(Buffer.toArray(tagBuf), 0, maxTags) else Buffer.toArray(tagBuf);
    let stage = if (stageRank(dup.stage) > stageRank(keep.stage)) dup.stage else keep.stage;
    let lastTouch = switch (keep.lastTouchAt, dup.lastTouchAt) {
      case (?a, ?b) ?Int.max(a, b);
      case (?a, null) ?a;
      case (null, b) b;
    };
    let survivor = {
      keep with
      email = email;
      phone = phone;
      address = address;
      company = company;
      source = source;
      notes = notes;
      tags = tags;
      stage = stage;
      agent = switch (keep.agent) { case (?a) ?a; case (null) dup.agent };
      lastTouchAt = lastTouch;
      createdAt = Int.min(keep.createdAt, dup.createdAt);
      events = pushEvent(keep.events, "Merged in contact #" # Nat.toText(dup.id) # " (" # dup.name # ")" # (if (stage != keep.stage) "; stage " # stageText(keep.stage) # " → " # stageText(stage) else "") # ".", now);
      updatedAt = now;
    };
    putContact(survivor);
    // The tombstone keeps nothing personal: everything useful moved to the survivor.
    putContact({
      dup with
      name = "Merged into #" # Nat.toText(keep.id);
      company = null;
      email = null;
      phone = null;
      address = null;
      notes = null;
      tags = [];
      agent = null;
      mergedInto = ?keep.id;
      events = [{ at = now; event = "Merged into contact #" # Nat.toText(keep.id) # "." }];
      updatedAt = now;
    });

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Merged #" # Nat.toText(dup.id) # " into #" # Nat.toText(keep.id) # ": " # Nat.toText(dupActs.size()) # " activities moved." # (if (kept.size() > 0) " Differing details were kept in notes." else ""))),
      ("contact", contactSummaryJson(survivor, book, now)),
    ]))));
  };

  // --- forget_contact ---

  func forgetContactTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?book = requireBook(p, cb) else return;
    let ?id = optNat(args, "contact_id") else return fail(cb, "'contact_id' is required.");
    let ?c = ownedContact(p, id, cb) else return;
    if (optBool(args, "confirm") != ?true) return fail(cb, "Erasure is permanent. Pass confirm=true to erase " # c.name # ".");
    let now = Time.now();

    var acts = 0;
    for (aid in idsOfN(activityIdsByContact, c.id).vals()) {
      switch (getActivity(aid)) { case (?a) { Map.set(activitiesById, nhash, aid, { a with summary = erasedText }); acts += 1 }; case (null) {} };
    };
    for (fid in idsOfN(followUpIdsByContact, c.id).vals()) {
      switch (getFollowUp(fid)) {
        case (?f) {
          let closed = if (f.status == #open) ({ f with status = #cancelled; closedAt = ?now }) else f;
          putFollowUp({ closed with task = erasedText; outcome = null });
        };
        case (null) {};
      };
    };
    for (did in idsOfN(dealIdsByContact, c.id).vals()) {
      switch (getDeal(did)) {
        case (?d) {
          let scrubbed = Array.map<LogEvent, LogEvent>(d.events, func(e) { ({ e with event = erasedText }) });
          putDeal({ d with title = "Deal #" # Nat.toText(d.id) # " (erased contact)"; lostReason = switch (d.lostReason) { case (?_) ?erasedText; case (null) null }; events = scrubbed });
        };
        case (null) {};
      };
    };
    for (qid in idsOfN(inquiryIdsByContact, c.id).vals()) {
      switch (getInquiry(qid)) {
        case (?q) putInquiry({
          q with
          subject = erasedText;
          message = erasedText;
          senderName = null;
          replyTo = null;
          replies = Array.map<Reply, Reply>(q.replies, func(r) { ({ r with text = erasedText }) });
          status = #closed;
          erased = true;
        });
        case (null) {};
      };
    };
    switch (c.agent) {
      case (?a) Map.delete(contactByAgent, thash, Principal.toText(p) # "#" # Principal.toText(a));
      case (null) {};
    };
    putContact({
      c with
      name = "Erased contact #" # Nat.toText(c.id);
      company = null;
      email = null;
      phone = null;
      address = null;
      source = null;
      tags = [];
      notes = null;
      agent = null;
      stageReason = null;
      erasedAt = ?now;
      events = [{ at = now; event = "Erased at a deletion request." }];
      updatedAt = now;
    });
    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Contact #" # Nat.toText(c.id) # " erased: " # Nat.toText(acts) # " timeline entries scrubbed, open follow-ups cancelled, inquiries closed. Deal values and dates remain in get_pipeline.")),
      ("contact_id", Json.int(c.id)),
      ("erased_at", Json.str(fmtLocal(now, book.tzOffsetMinutes))),
    ]))));
  };

  // --- SDK CONFIG & HTTP WIRING ---

  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null;
    serverInfo = {
      name = "crm-lead-ledger";
      title = "CRM & Lead Ledger";
      version = "0.1.0";
    };
    resources = [];
    resourceReader = func(uri) { Map.get(appContext.resourceContents, Map.thash, uri) };
    tools = tools;
    toolImplementations = [
      ("setup_crm", setupCrmTool),
      ("find_businesses", findBusinessesTool),
      ("submit_inquiry", submitInquiryTool),
      ("my_inquiries", myInquiriesTool),
      ("reply_to_inquiry", replyToInquiryTool),
      ("add_contact", addContactTool),
      ("find_contacts", findContactsTool),
      ("get_contact", getContactTool),
      ("set_stage", setStageTool),
      ("log_activity", logActivityTool),
      ("schedule_follow_up", scheduleFollowUpTool),
      ("complete_follow_up", completeFollowUpTool),
      ("get_agenda", getAgendaTool),
      ("add_deal", addDealTool),
      ("move_deal", moveDealTool),
      ("get_pipeline", getPipelineTool),
      ("merge_contacts", mergeContactsTool),
      ("forget_contact", forgetContactTool),
    ];
    beacon = ?beaconContext;
  };

  transient let mcpServer = Mcp.createServer(mcpConfig);

  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = ?authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { mcpResponse };
      case (null) {
        if (req.url == "/") {
          // Query responses need certification on the non-raw gateway; punt to an
          // update call, which is exempt.
          {
            status_code = 204;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = ?true;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (await HttpHandler.http_request_update(ctx, req)) {
      case (?res) { res };
      case (null) {
        if (req.url == "/") {
          {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8("<h1>CRM &amp; Lead Ledger MCP Server</h1><p>Contacts, interaction history, follow-ups, and deals as canister state — with an inquiry inbox any customer's agent can write to. MCP endpoint at <code>/mcp</code>. Authenticate with an <code>x-api-key</code> header.</p>");
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  /// Mint a stable API key bound to the caller's principal.
  /// The raw key is returned once and never stored in plaintext.
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    return await ApiKey.create_my_api_key(authContext, msg.caller, name, scopes);
  };
};
