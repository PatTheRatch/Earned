# Strava

**Status: proposed, not built.** Nothing in this document exists in the repository.

Written because the question came up while testing, and because the obvious reason to do
it turns out to be the wrong one. The interesting reason is real, and it is not the one
most people would give.

---

## 1. The reason you would expect, and why it is weak

> "Users record on Garmin / Wahoo / Zwift / Peloton, so Earned needs to read Strava to see
> their workouts."

Mostly false, and worth knowing before spending a fortnight on OAuth. Every one of those
platforms can write directly into Apple Health:

| Source | Reaches Apple Health |
|---|---|
| Apple Watch, iPhone Workout app | Natively |
| Garmin | Garmin Connect → Settings → Apple Health |
| Wahoo | ELEMNT app → Apple Health |
| Peloton | Peloton app → Apple Health |
| Strava's own recordings | Strava → Settings → Health |
| Zwift, Nike Run Club, and most others | An Apple Health toggle in their own settings |

Earned already reads all of it, with provenance, through one integration
(`app/Earned/Health/HealthImporter.swift`). A Garmin run that reaches Health arrives
stamped `com.garmin.connect.mobile` and counts as `appVerified` exactly as an Apple Watch
run does. Adding Strava buys **coverage of a gap that is mostly a settings toggle away
from being closed**, and the honest version of that support answer is one sentence:
*"turn on Apple Health sync in the app you record with."*

That is not nothing — a toggle the user never finds is a toggle that does not exist, and
"it just works" is worth real money. But it is a convenience argument, not an architectural
one, and it does not justify the cost on its own.

## 2. The reason that is actually interesting

**Strava is a path to server-authoritative completion, and Earned currently has none.**

Today the trust boundary is honest but incomplete. The Contract Envelope made the server
authoritative for a hardened commitment's *terms* — the threshold, the roster, the
hardening moment — and the whole of `accountability-architecture.md` §4 exists for that.
But whether the user actually ran is still the device's word:

> | Progress and reliability figures shown to partners | **Device** | The server has no
> HealthKit and no ledger. Self-reported, and labelled as such (§7, D6) |

**S9** commits to the label *"until server-authoritative resolution exists"*, and §23 lists
it as a known limitation. A partner reading "18 of 30 minutes" on an approval page is
reading a number the requester's phone produced.

Strava is one of the few sources that can be read **by the server, from the source, without
the device in the loop**. A webhook fires, the server fetches the activity with the
athlete's own token, and the server knows something it did not learn from the app. That is
the first crack in §23's third bullet, and it is the only reason in this document worth the
build cost.

It also narrows, though does not close, §23's fourth bullet — *a patched client still
bypasses everything on its own device*. A patched client cannot fabricate a Strava
activity that Strava never recorded.

## 3. What it does not fix

Stated first, in the house style, so it is not discovered later.

- **It is not identity.** Strava proves an activity was recorded on some account, not that
  the person who owes the commitment performed it. Handing a friend your watch still works.
  Same limitation as §2.2's partner tiers, and for the same reason.
- **Strava activities can be manual.** `manual: true` on the activity means a human typed
  it into Strava. That is the user's word wearing a different lab coat, and it must map to
  `WorkoutEvidence.selfReported` exactly as HealthKit's `wasUserEntered` does — otherwise
  connecting Strava would *weaken* verification for anyone who uses it, which would be an
  absurd outcome for a feature sold as stronger proof.
- **It does not make the ledger server-side.** Resolution still happens on device; the
  server would gain a second opinion, not the record. §23's reinstall hole is untouched.
- **It adds a dependency Earned's design says it must not need.** Every gate must keep
  working through any outage of ours (**S8**) and of Strava's. A missing webhook must never
  mean a locked phone — see §8.

## 4. Two things that will bite, both silently

### 4.1 Double-counting, if Strava reaches Earned twice

This is the sharp one, and it is a bug the current dedupe **would not catch**.

A user with Strava → Apple Health sync *and* a direct Strava connection produces one run
that arrives twice: once as an `HKWorkout` with HealthKit's UUID, once as a Strava activity
with Strava's id. `EarnedState`'s dedupe is by workout id, and those two ids differ, so a
30-minute run would satisfy a 60-minute commitment.

The fix cannot be id-based. Options, in preference order:

1. **Prefer one source per workout, decided by overlap.** Two workouts of the same activity
   type whose time ranges overlap are one workout. Keep the more authoritative record and
   drop the other. Needs a tolerance — clocks and upload timing differ by seconds — and
   that tolerance is a rule the domain should own and test, not a constant somebody picks
   in the importer.
2. **Correlate on HealthKit's external identifier.** Strava sets
   `HKMetadataKeyExternalUUID` on workouts it writes to Health; if that carries the Strava
   activity id, the two records can be matched exactly. **Verify this before relying on
   it** — it is a claim about another app's behaviour, and if it is wrong the fallback is
   option 1 anyway.
3. **Refuse to run both at once.** Connecting Strava directly disables Strava-sourced
   HealthKit workouts. Crude, and it silently changes what counts, which this project's
   own history says is the failure mode to avoid.

Whichever is chosen, it needs a test with two real overlapping records before any of it
ships. This is exactly the shape of the bug that got caught this week — a value that looks
unique, is not, and produces a wrong total rather than an error.

### 4.2 Calories are not the same calories

Earned's `totalActiveEnergy` means **active** kilocalories — energy above resting — because
total energy can be non-zero for an activity that demanded nothing. Strava's detailed
activity exposes `calories`, and it is *not* the same figure: for rides it is derived from
kilojoules of work, and it is Strava's own estimate under its own model.

Feeding Strava's `calories` into a requirement calibrated against Apple's active energy
would move the bar by an unknown amount, in an unknown direction, invisibly. Either
establish the mapping deliberately and document it, or do not accept Strava as a source for
energy-based commitments at all and say so in the picker. Do not assume the units agree
because they share a word.

## 5. Where the credentials live

The same argument as grant signing keys, and the same answer.

**No Strava client secret ships in the app, and no Strava token reaches the device.** An
app that held a token could read the user's Strava directly and then tell the server what
it found, which is the self-reported path this whole feature exists to escape. If the
device is in the loop, there is no point being in Strava at all.

So the OAuth flow is **server-mediated end to end**:

```
app                     earntherest.com              Strava              Supabase
 │ open ASWebAuth ──────►│ /strava/connect            │                   │
 │                       │ + state (signed, short-lived, bound to account) │
 │                       ├───── 302 /oauth/authorize ►│                   │
 │                       │                            │ user approves     │
 │                       │◄──── 302 /strava/callback ─┤ ?code=…&state=…   │
 │                       ├─ POST /oauth/token (client_secret) ───────────►│
 │                       │◄─ access, refresh, expires_at, athlete ────────┤
 │                       ├─ store, encrypted ────────────────────────────►│
 │◄── 302 earned://strava/connected ─┤                │                   │
```

The `state` parameter is not decoration: it is the only thing tying the callback to the
account that started the flow, and a callback that trusted an unauthenticated account id
would let anyone attach their Strava to someone else's Earned account. Sign it, scope it to
the account, expire it in minutes, and use it once.

Tokens are stored the way contact details are (§14.1): ciphertext in Postgres, key in the
platform secret store, no policy on the table, reachable only by the edge function's
service role. A refresh token is a standing read grant on someone's location history for as
long as it lives; treat it accordingly.

Scope: **`activity:read_all`** if private activities must count, `activity:read` otherwise.
Ask for the narrower one unless the product needs the wider — and note in the consent copy
which was asked for, because "Earned can see your private activities" is a sentence the
user deserves before they tap, not after.

## 6. Webhooks

Strava's Webhook Events API pushes activity creation rather than requiring a poll, which
matters here: a user standing at a locked phone should not wait for a polling interval.

Two mechanics worth knowing before designing around them:

- **Validation handshake.** Creating a subscription makes Strava `GET` the callback with
  `hub.mode`, `hub.challenge` and `hub.verify_token`; the endpoint must echo the challenge
  as `{"hub.challenge": "…"}` and must check `hub.verify_token` matches the one it sent.
- **One subscription per application.** Not per user. A single callback URL receives every
  athlete's events, keyed by `owner_id`. That is fine for one edge function, and it means
  the callback is a high-value endpoint: it is the whole app's ingress.

The event carries `object_id`, `owner_id`, `aspect_type` and `object_type` — **not the
activity**. The handler must fetch `GET /api/v3/activities/{id}` with that athlete's token,
refreshing it if `expires_at` has passed. Handle `aspect_type: "delete"` and `"update"`:
an activity deleted or edited on Strava after it satisfied a commitment is a real case, and
the right answer is almost certainly *the commitment stays resolved* — Earned's ledger is
append-only and a completion that was true when recorded does not become false — but that
is a decision to make deliberately rather than by omission.

Rate limits exist and are per-application, not per-user, which means one busy day for all
users shares one budget. **Check the current limits in Strava's developer documentation
rather than trusting a number written here**; they have changed, and a limit assumed rather
than read is a limit discovered in production.

## 7. Matching an activity to a commitment

Here is the part that does not fit the existing design, and it should be decided before any
code is written.

The server **cannot currently do this**, because the Contract Envelope deliberately does
not carry the requirement. From §4:

> Note what is *not* sent: the requirement, the restriction profile, any workout, any
> progress.

That exclusion was right when the envelope's job was to hold accountability *terms*. Server
-side verification needs the server to know what counts as done, which means either:

- **(a) The envelope gains the requirement.** Activity filter, metric, target, verification
  tier. Not a privacy expansion in substance — §13 already discloses the requirement to
  partners in the request snapshot — but it is a real change to what the server holds for
  every commitment, not only for ones that reach a request. It also gives the server a
  second implementation of `Requirement.progress(over:)`, which must not drift from
  EarnedKit's; the hardening fixtures (§19) are the precedent for how to keep two
  implementations honest.
- **(b) The server records verified activities only, and the device matches them.** The
  server stores "this athlete ran 5.2 km at 07:14, vouched for by Strava" and the app pulls
  that as an evidence source. Far smaller change, keeps one implementation of the rules —
  but the server no longer knows whether anything was satisfied, so **it is not
  server-authoritative resolution**, and §2's entire justification evaporates. It is a
  better `HealthImporter`, nothing more.

**(a) is the only version that buys what §2 claims.** It is also the larger change, and it
should be recognised as reopening a decision §4 made on purpose rather than smuggled in as
an implementation detail.

## 8. Offline and outage, which are not optional

§11's rule is absolute and this feature does not get an exemption: *the device must never
be more locked because a server is unreachable.*

- Strava webhook never arrives → the commitment is satisfied by HealthKit as it is today,
  or by the Solo route on the local clock. A Strava outage must not extend anyone's
  restriction by a second.
- Earned's server unreachable → the device behaves exactly as it does now.
- User has not connected Strava → everything works as it does now. This is an *additional*
  evidence source, never a required one.

The temptation to make an `appVerified` commitment wait for server confirmation should be
resisted, and the reason is in **S8**: a product that takes away access to someone's phone
does not get to make its own uptime their problem.

## 9. What must be decided before building

Open, in the style of §21.2 — these are questions for a person, not defaults to be guessed.

| # | Decision |
|---|---|
| **T1** | Does the Contract Envelope gain the requirement (§7 option **a**)? Without it this is a convenience feature, not a trust-boundary change. |
| **T2** | **Strava's API Agreement restricts displaying an athlete's data to anyone but that athlete.** Earned's partner page shows progress figures to other people. Whether a derived figure — "18 of 30 minutes" — falls inside that restriction is a terms question with a real answer, and it is not one to guess: the partner page is the product. Read the current agreement; if it is unclear, ask Strava before building, not after. |
| **T3** | Does a Strava activity deleted or edited after it resolved a commitment change anything? (Proposed: no — the ledger is append-only and a completion true when recorded stays true. Decide it explicitly.) |
| **T4** | Is Strava's `calories` accepted for energy-based commitments, under a documented mapping, or refused (§4.2)? |
| **T5** | Which dedupe strategy (§4.1), and what time tolerance counts two records as one workout? |
| **T6** | `activity:read` or `activity:read_all`, and what the consent copy says about it. |

## 10. Build order, if it is approved

Each step is verifiable on its own, in the manner of `deployment.md`.

1. **Decide T1 and T2 first.** T2 can invalidate the feature outright, and T1 decides
   whether it is worth building at all. Nothing else starts until both are answered.
2. **A Strava application, and its review.** Registration is immediate; approval for
   anything beyond a developer's own account is not. Start it early — the same lesson as
   Family Controls (Distribution), which is also sitting in a queue.
3. **Token storage** — table, encryption, refresh. Testable with no webhook and no app: run
   the OAuth flow by hand, confirm a token round-trips and refreshes after expiry.
4. **The callback endpoint**, with the validation handshake and `verify_token` check.
   Verify by creating the subscription and watching it succeed.
5. **Activity ingestion**, with `manual` mapped to `selfReported` and provenance recorded.
   Verify by recording a real activity and finding the row.
6. **Dedupe** (T5), with a test built from two real overlapping records — one from
   HealthKit, one from Strava, the same run. This is the step that must not be skipped for
   time; §4.1 is the bug that would otherwise ship silently.
7. **Matching** (T1's answer), with shared fixtures against EarnedKit so the two
   implementations of "done" cannot drift.
8. **The connect/disconnect UI**, including revocation. A user who disconnects must have
   their tokens deleted, not merely marked inactive — §15's retention rules apply to a
   standing read grant on someone's movements more than to anything else Earned holds.

---

## 11. Recommendation

**Not yet, and not for the reason it would usually be built.**

The coverage argument is weak (§1): almost every device a user might record on already
reaches Apple Health, and Earned already reads that with full provenance. Building Strava
for coverage would be a fortnight spent replacing a settings toggle.

The server-authoritative argument (§2) is genuinely strong — it is the first real answer to
§23's "progress is self-reported", which is the largest honest gap left in the product.
But it only holds if T1 goes the way that reopens §4's deliberate exclusion, and it is
gated behind T2, which could make the partner page — the centre of the product — legally
awkward to keep as it is.

So: answer **T2 first**, because it is cheap to answer and can end the discussion. Then
**T1**, because it decides whether this is a trust-boundary change or a nicer importer. If
both land well, this is the most valuable thing left on the roadmap after the launch gates.
If either does not, the one-sentence support answer from §1 is a perfectly good product
decision, and should be written into the onboarding copy instead.

Either way it sits behind §20's launch gates. A verification source that is not yet needed
should not delay the ones that are.
