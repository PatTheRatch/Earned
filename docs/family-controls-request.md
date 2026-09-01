# Requesting Family Controls (Distribution)

Everything needed to submit the request, drafted from what the app actually does. Nothing
here can be submitted by anyone but Patrick — it is a form on Apple's developer site, tied
to the developer account.

**Why it is the long pole.** Family Controls (Development) is self-serve and is all a device
build needs. Distribution is reviewed by a human at Apple, takes days to weeks, and is
required before TestFlight. Every other remaining task is code; this one is a queue. Submit
it before the work that depends on it is finished, not after.

---

## 1. Where

Apple's developer contact form, under Family Controls distribution requests:

> https://developer.apple.com/contact/request/family-controls-distribution

Sign in with the account that owns `com.pattheratch.earned`.

**The exact fields have changed before and may differ from what is drafted below.** The
answers here are written as prose blocks to paste and trim, not as a field-by-field script.
If a question appears that nothing here answers, §3's facts are the source to answer it
from — they are what the code does.

## 2. What to request, and how many times

The entitlement is granted **per bundle identifier**, and each Screen Time extension is a
separate bundle identifier with its own review.

| Target | Bundle id | Request now? |
|---|---|---|
| The app | `com.pattheratch.earned` | **Yes** — this is what unblocks TestFlight |
| `DeviceActivityMonitor` extension | `com.pattheratch.earned.monitor` | **Yes** — it is what makes a deadline land on time |
| `ShieldConfiguration` extension | `com.pattheratch.earned.shield` | **Yes** — built, and it is the screen a blocked app shows |

Request **all three**. They are separate queues, so starting them together costs nothing and
saves two more waits — and this is the whole reason the shield extension was built before
the request rather than after it. An approved app and monitor with an unapproved shield is
not a partial win: the archive contains an extension whose entitlement was never granted,
and the upload is refused.

**The distribution review is not what gates seeing it work.** Family Controls
(*Development*) is self-serve for all three bundle ids, so a development build on your own
phone renders the shield today. The review below is only the road to TestFlight.

The monitor's own description is short, and the same argument as the app's:

> The extension applies the same restrictions the app does, at the moment a commitment the
> user set falls due, so that a deadline is enforced whether or not the app happens to be
> running. It reads a small file the app wrote — which apps to shield, and when — and
> writes those shields. It performs no monitoring of activity, collects nothing, and reads
> no usage data; `DeviceActivityMonitor` is used purely as a scheduled wake-up, not to
> observe device activity.

That last sentence is worth keeping. The framework's name suggests surveillance and the use
here is the opposite, so saying so plainly costs a line and pre-empts the obvious question.

The shield extension's description is shorter still, because it does less than either:

> The extension supplies the text and colours of the screen iOS already shows when the user
> opens an app they have restricted. It replaces Apple's generic wording with the specific
> commitment the user made, read from a short file the app wrote in advance. It makes no
> decision about what is blocked, performs no monitoring, reads no usage data, and has no
> network access.

The point a reviewer will look for is that this extension cannot *cause* a restriction —
it only describes one the user asked for. Say it in those words.

## 3. The facts the request rests on

Written out because the case is unusually strong and it would be a shame to undersell it.
Every claim here is checkable in the repository.

**Earned restricts the person holding the phone, at their own prior request.** Authorization
is `.individual` (`app/Earned/Enforcement/ScreenTimeController.swift`), not
`.child`. There is no parent, no child, no supervised device, no organisation, and no
dashboard showing anyone else's activity. The user is both the person choosing the
restriction and the person restricted.

**The app cannot see which apps it is blocking.** Selection goes through Apple's own
`FamilyActivityPicker`, and what comes back are opaque tokens
(`app/Earned/Enforcement/RestrictionTokenLabel.swift`). Earned shields what the user picked
without ever learning what it is; the names and icons on screen are drawn by system-supplied
`Label` views that the app cannot read. This is deliberate, is written into the product's
own privacy principle (NORTHSTAR §34), and means Earned holds no record of a user's app
choices even in principle.

**No usage data is collected, at all.** Earned does not read screen time, launch counts,
durations, or categories. It writes shields; it does not observe behaviour. The only thing
it knows is whether a commitment the user wrote has been met.

**The restriction is bounded by a commitment the user authored.** The user creates a
commitment — what counts as done, by when, and which apps are unavailable until then. The
shield exists only while that commitment is unmet, and lifts the moment it is satisfied.

**The user is never trapped.** Three exits, all in the product today: a small balance of
free overrides; a solo override that becomes available after a delay the user set, behind
deliberate friction; and, optionally, asking people they nominated to release them early.
Nothing requires Earned's servers to be reachable — every gate and every exit runs on the
device's own clock, so an outage on our side can never extend a restriction.

**Shields fail open when authorization goes away.** If Screen Time permission is revoked,
Earned drops every shield rather than continuing to act on stale authority
(`ScreenTimeController.clear()`, called from `EarnedStore.refreshShielding()` on launch and
on every return to the foreground).

## 4. Draft answers

### What the app does, and why it needs Family Controls

> Earned is a self-restriction app. A person sets themselves a commitment — for example
> "run 30 minutes by 10am" — and chooses which apps become unavailable to them until that
> commitment is met. When they complete it, the restriction lifts.
>
> Family Controls is what makes the commitment real rather than advisory. Without
> `ManagedSettingsStore`, Earned could only display a message asking the user not to open
> the apps they had already decided they did not want to open, which is precisely the
> decision they are asking for help with.
>
> Earned uses `.individual` authorization. There is no parent-child relationship, no
> supervised device and no management of anyone other than the person using the app. The
> user restricts themselves, in advance, on terms they wrote.

### How the user selects what is restricted

> Through `FamilyActivityPicker`. Earned receives opaque `ApplicationToken`,
> `ActivityCategoryToken` and `WebDomainToken` values and never resolves them to app
> identities — names and icons shown in the app are rendered by the system's own `Label`
> views. Earned therefore cannot see, store or transmit which apps a user has chosen,
> which is a deliberate design constraint rather than a side effect.

### What data is collected

> None relating to Screen Time. Earned does not read usage data, launch counts, durations
> or categories, and does not use `DeviceActivityReport`. It applies shields and does not
> observe behaviour.
>
> Commitments and workout data stay on the device. An optional feature lets a user nominate
> people who can release them from a commitment early; those people are shown the
> commitment's title, its deadline and a progress figure for that commitment only. They are
> never shown app selections, app usage, or anything about which apps are restricted —
> Earned could not show them that even if it wanted to.

### How the user removes a restriction

> Restrictions lift automatically when the commitment is met. Three additional exits exist
> so that a user is never trapped: a small balance of free overrides; a solo override that
> becomes available after a waiting period the user chose when creating the commitment,
> behind deliberate friction; and optionally asking nominated people to approve an early
> release.
>
> All of these run on the device's own clock and require no network access, so the app's
> own availability can never extend a restriction. If Screen Time authorization is revoked
> in Settings, Earned clears every shield rather than continuing to act on it.

### Category of use

> Self-restriction / digital wellbeing for an individual adult user. Not parental controls,
> not device management, not employee or organisational monitoring.

## 5. Before submitting

- [ ] An App Store Connect record exists for `com.pattheratch.earned` (the form generally
      wants an app to point at).
- [ ] The App ID has Family Controls enabled (already done — `app/README.md` §"One-time
      setup").
- [ ] A privacy policy is reachable. `web/` serves one at `earntherest.com/privacy`, and it
      should say what §4 says: no Screen Time data is collected, and app selections are
      unreadable to Earned.
- [ ] The description above matches what the app currently does. If enforcement or the
      override routes change materially before approval, the request should say what
      shipped rather than what was planned.

## 6. After submitting

Expect days to weeks, with no progress indicator. Meanwhile:

- Development builds keep working. Family Controls (Development) is unaffected.
- Family testing can proceed on devices plugged into a Mac and built from Xcode.
- If Apple asks for clarification, answer from §3 — every claim there is checkable in the
  repository, which is a much better position than most applicants are in.

If it is refused, the reason will name what Apple wants changed. The most likely areas are
the privacy policy's specificity, or wanting the App Store listing to make the
self-restriction purpose unmistakable to a user *before* they grant Screen Time access.
Neither would be a design problem.
