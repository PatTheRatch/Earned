# EARNED

**North Star Product Document**

v0.5 · August 2026

> Do what matters first. Earn the rest.

---

## 1. The Idea

Earned is a commitment system that changes the default relationship between a person and their devices.

Most digital wellbeing products ask people to use distracting technology less.

Earned approaches the problem differently.

**Access to distracting technology is conditional.**

The user's phone remains capable of doing the things necessary to live their life: communicating with people, navigating, getting around, listening to music during a workout, and handling other essentials.

Everything else can be placed behind Gates.

A Gate represents something the user has decided matters more than optional phone use.

- Drink some water.
- Complete a workout.
- Go for a run.

A user makes that decision while thinking clearly. Earned then enforces the decision later, when scrolling Instagram is considerably more appealing than honoring yesterday's promise.

The basic loop is:

**Commit → Restrict → Complete → Verify → Unlock.**

Earned does not exist to motivate users.

It exists to make their existing intentions harder to ignore.

---

## 2. The Problem

People frequently know what they want to do and still don't do it.

The problem is often not knowledge.

It is incentive structure.

Opening Instagram requires almost no effort.

Going for a run requires changing clothes, leaving the house, tolerating discomfort, and surrendering some scarce free time.

A reminder does little to alter that equation.

> "Time to drink water." — Dismiss.
>
> "Remember your workout." — Dismiss.

The desired behavior remains optional while the distraction remains immediately available.

Earned changes the environment instead.

When a commitment becomes due, the distraction disappears.

The user can still choose not to drink water.

They simply cannot choose Instagram instead.

---

## 3. Product Thesis

**Consequences change behavior more effectively than reminders when the user has voluntarily chosen the consequence in advance.**

Earned turns intentions into enforceable personal contracts.

The user decides:

- what they will do;
- when it must be completed;
- how completion will be verified;
- which digital privileges depend on completing it;
- how difficult escaping the commitment should be.

Earned enforces that contract.

---

## 4. North Star

**Earned succeeds when the user no longer needs Earned.**

The goal is not maximum engagement with the product.

The goal is behavioral independence.

A successful user eventually drinks water without being gated.

They exercise because exercise has become part of their life.

They stop reflexively reaching for digital stimulation whenever boredom appears.

The ideal long-term journey is:

External enforcement → repeated behavior → habit → internalized behavior → reduced enforcement → independence.

Deleting Earned because it successfully became unnecessary is a successful outcome.

---

## 5. Core Mental Model: Gates

Earned operates through Gates.

A Gate represents a condition that must currently be satisfied for restricted digital privileges to remain available.

Examples:

- **Hydration Gate** — Drink some water every 60 minutes.
- **Exercise Gate** — Complete a workout by 10:00 AM Saturday.
- **Running Gate** — Run for 30 minutes by 8:00 AM Tuesday.

A user may have multiple Gates active simultaneously.

### The central rule

**Full Access = every currently active Gate is satisfied.**

- If Hydration is satisfied but Exercise is not: **Restricted.**
- If Exercise is satisfied but Hydration expires: **Restricted.**
- If both are satisfied: **Unlocked.**

Gates operate independently but combine into one access state.

---

## 6. Essential Access vs Earned Access

Earned does not make a smartphone unusable.

It separates functionality into two conceptual layers.

### Essential Access

Available even while restricted.

Examples may include:

- Phone
- Messages
- navigation
- transportation
- essential communication
- email where appropriate
- workout-enabling tools
- music/audio required for exercise
- authentication and other critical utilities

For Patrick's initial configuration, examples include:

- Phone
- Messages
- email
- Maps
- Citymapper
- Spotify

### Earned Access

Optional digital consumption and convenience.

Examples include:

- Instagram
- social media
- YouTube
- games
- ChatGPT and other AI applications
- Safari
- Chrome
- food delivery applications
- entertainment applications

The user ultimately selects which applications belong behind the Gate.

Earned may suggest sensible defaults, but the user owns the classification.

### Restrictions belong to Gates

There is no single global "restricted" list. **Each Gate carries its own
restriction profile**, and what is actually in force at any moment is the
**union of the profiles of every currently-unsatisfied Gate.**

This matters because the Gates are not equally severe:

**Hydration Gate unsatisfied** — extremely restrictive. The phone retains bare
communication and critical function only. Before the morning's first water,
even email and most otherwise-useful apps may be gone.

**Exercise Gate unsatisfied** — useful-life applications remain: phone,
messages, email, maps, transit, workout audio. Optional consumption does not:
social, games, video, browsers, AI apps, food delivery.

With both unsatisfied, the union naturally produces the stricter result. No
Gate silently softens another.

### Principle

**A restricted device should remain useful for living but boring for avoiding life.**

---

## 7. Hard Interruption

When a Gate becomes unsatisfied, enforcement begins immediately.

There is no:

- "finish what you're doing";
- five-minute grace period;
- one final video;
- one final game;
- lock-on-next-open behavior.

If the Hydration Gate expires while Instagram is being used, Instagram becomes unavailable.

The consequence should occur at the moment the condition changes.

Warnings may occur beforehand.

The deadline itself is not negotiable.

---

## 8. The Lock Experience

The lock screen should be extremely simple.

It is not a coaching surface.

It is not an advertising surface.

It is not a motivational feed.

**It explains the contract.**

Example:

> 🔒 Still locked
>
> 💧 Drink some water
>
> 🏃 Complete any workout
>
> Satisfy all active requirements to unlock.

For measurable commitments:

> 🔒 Still locked
>
> 🏃 Run for 30 minutes
>
> 18 / 30 min
>
> 12 minutes to go.

The product may occasionally be playful, but never verbose.

**The lock screen is a receipt.**

---

## 9. Commitment Creation

Creating a commitment should feel deliberate without feeling bureaucratic.

The user is guided through one decision per screen.

A typical flow:

1. What will you do?
2. By when?
3. What will count as completion?
4. What should be restricted if you don't do it?
5. How should completion be verified?
6. What are the override rules?
7. Commit 🔒

Users may create commitments:

- for tomorrow;
- later today;
- for several days;
- for the next week;
- for the next month;
- whenever they choose.

Earned does not require users to adopt a recurring workout calendar.

A user can plan as much or as little of their future as they currently know.

### Recurring plans

A user who knows their week should not have to enter it one day at a time.

> Run 30 min · Mon/Wed/Fri · next 4 weeks

A **plan** generates individual commitment occurrences, each with its own
eligible window, deadline, hardening clock, progress and resolution. Occurrences
are ordinary commitments in every respect — the plan is a way of creating them,
never a separate source of truth for Gate state.

Making a plan is one act of commitment, not several. Every occurrence's
correction window runs from the moment the plan is made, not from its own
calendar day — so the whole plan hardens together, shortly after creation, well
before its later weeks arrive. A user cannot adjust week three on the Monday
of week three. This is deliberate: a plan should not be a softer way of making
the same commitments one at a time. If you are not ready to follow through on
the whole plan, do not make it. The app says so before the user commits.

Cancelling a plan withdraws occurrences still inside their correction window,
and also occurrences whose eligible window has not opened yet — since the plan
as a whole hardens so quickly, this is what keeps cancellation meaningful for
weeks that have not started. Anything already live — its window open, whether
hardened or not — is a contract in its own right and survives.

---

## 10. Deadlines, Not Appointments

Exercise commitments are primarily deadline-based.

A user does not need to promise:

> "I will run between 8:00 and 9:00 AM."

Instead:

> Complete a workout by 10:00 AM Saturday.

Any qualifying activity completed during the eligible period before that deadline may satisfy the commitment.

This preserves flexibility while maintaining accountability.

Human-friendly presets may include:

- Morning
- Afternoon
- Evening
- Custom deadline

These resolve to explicit deadlines.

### The eligible period

Every commitment carries an explicit **`eligibleFrom`** — the moment its window
opens. A workout counts toward it only if the workout started at or after that
instant.

- For a one-off commitment, `eligibleFrom` is creation time: a user cannot
  commit to a run they have already done.
- For an occurrence generated by a recurring plan, it is **midnight at the start
  of that occurrence's own calendar day**, never earlier than the plan's
  creation. Monday's run therefore cannot satisfy Wednesday's obligation.

There is deliberately **no upper bound** at the deadline. The obligation persists
past its deadline until resolved, so a late workout must still be able to clear
outstanding debt (§16).

If the requirement has not been satisfied when the deadline arrives, its Gate becomes unsatisfied and enforcement begins.

Passing the deadline does not eliminate the obligation.

---

## 11. Commitment Hardening

Earned distinguishes between planning and commitment.

After creating a commitment, the user receives a configurable correction window.

Patrick's initial preference: **2 hours.**

During this period, mistakes and legitimate immediate changes can be corrected.

### Short-fuse commitments

A commitment due soon must not be able to outlive its own correction window unhardened.

The effective correction window is therefore:

**min(configured window, a fraction of the time until the deadline).**

Example: with a 2-hour configured window, a commitment due 2 hours from now might harden after ~15 minutes — enough to fix a typo, not enough to quietly un-commit.

After the correction window expires, the contract hardens.

A hardened commitment cannot normally be made easier.

---

## 12. The Monotonic Commitment Principle

This is a core product invariant.

**Once hardened, a commitment may become harder but never easier.**

The user may:

- add another restricted application;
- increase required workout duration;
- increase required distance;
- strengthen verification;
- add another restriction.

The user may not:

- remove a restricted application;
- decrease workout duration;
- decrease required distance;
- weaken verification;
- move the deadline merely because it has become inconvenient;
- otherwise reduce the burden of the existing contract.

If a legitimate situation requires making the commitment easier, the user is no longer editing the contract.

They are requesting an Override.

---

## 13. Exercise Gate

The first Earned MVP should support a deliberately simple exercise commitment.

**Patrick v1**

Requirement: Any qualifying workout recorded in Apple Health.

The goal at this stage is consistency, not optimized training.

Later versions should allow richer requirements. Examples:

- Any workout
- Any workout ≥ 10 minutes
- Exercise ≥ 30 minutes
- Run ≥ 30 minutes
- Run ≥ 5 km
- Cycle ≥ 45 minutes
- Run/walk ≥ 5 miles

The architecture should therefore treat verification rules as configurable rather than hard-coding "workout exists."

### Activity and amount are separate dimensions

A requirement is an **activity filter** plus a **completion metric**, never one
fused idea. "Run 30 minutes" must not be satisfiable by half an hour of cycling.

| Activity filter | Completion metric |
|---|---|
| any workout | a qualifying workout exists |
| running | total duration |
| walking | total distance |
| cycling | |
| strength | |
| extensible | |

Quantitative metrics accumulate across qualifying workouts (§14) unless a future
single-session option says otherwise. The activity dimension is designed to map
cleanly onto HealthKit activity types.

---

## 14. Workout Progress

Where logically possible, workout progress can accumulate.

Example:

> Commitment: Run for 30 minutes.
>
> Morning: 18 minutes completed.
>
> Remaining: 12 minutes.

The user may complete another 12 minutes later.

Likewise:

> 5 km required
>
> 3.2 km morning + 1.8 km evening = 5 km.

Future commitment types may optionally require a single continuous session, but accumulation is a valid default for quantitative goals.

Partial completion does not automatically forgive the remaining requirement.

---

## 15. Exercise Verification

Earned should support different levels of verification.

The simplest level trusts the existence of the relevant Apple Health workout.

More stringent contracts may require supporting evidence.

Possible verification signals include:

- workout type;
- duration;
- distance;
- active energy;
- heart-rate activity;
- movement data;
- other appropriate HealthKit metrics.

The purpose is not fraud detection.

The purpose is allowing users who know they tend to negotiate with themselves to choose stronger evidence.

Verification strength is part of the contract.

Once hardened, verification may become stricter but not weaker.

---

## 16. Workout Debt

Missing a workout deadline creates Workout Debt.

Debt persists beyond the original day.

Example:

> Saturday: Workout due. Not completed.
>
> Sunday: The obligation still exists.

The user does not regain Earned Access merely because the calendar changed.

### MVP debt rule

**Workout debt does not compound. Maximum debt: 1 workout.**

Example:

> Saturday workout missed. Debt = 1.
>
> Monday also contains a scheduled workout. Debt remains 1.
>
> The user completes a qualifying workout Monday.
>
> That workout satisfies the outstanding obligation and Monday's requirement.
>
> Debt returns to zero.

Future versions may allow users to choose accumulating debt.

That is explicitly outside the initial implementation.

---

## 17. Hydration Gate

Hydration serves a different purpose from exercise.

Earned is not trying to become a water-tracking application.

**The Hydration Gate is a behavioral interrupt.**

Patrick's desired behavior:

> Periodically force me to remember to drink some water before I continue consuming optional digital content.

No volume needs to be tracked.

The user simply acknowledges:

> I drank some water.

This is intentionally trust-based.

---

## 18. Rolling Hydration Timer

Hydration operates on a rolling timer.

Patrick's initial configuration: **60 minutes.**

Example:

> 08:00 → water acknowledged. Gate satisfied.
>
> 09:00 → timer expires. Gate unsatisfied. Restricted apps become unavailable.
>
> 09:17 → water acknowledged. Gate satisfied.
>
> Next expiry: 10:17.

The interval should be configurable.

The timer begins when water is acknowledged, not according to fixed clock checkpoints.

### Active hours

The Hydration Gate runs only during a configurable active-hours window (for example, 08:00–22:00).

Outside active hours, the Gate is dormant: no expiry, no enforcement, no 3 AM nagging.

**The window opens unsatisfied.** There is no free interval at the start of the
day. From the moment active hours begin, the Hydration Gate is closed and its
restriction profile applies, until water is acknowledged. Acknowledging starts
the rolling interval; when that expires the Gate closes again.

> 08:00 — active window begins. Hydration **unsatisfied**; water-specific
> restrictions apply immediately.
>
> 08:07 — water acknowledged. Hydration **satisfied**; the 60-minute rolling
> timer starts.
>
> 09:07 — timer expires. Hydration **unsatisfied** again.

Only an acknowledgment made inside the current window counts: yesterday's water
does not open today.

---

## 19. Multiple Gates

Every Gate evaluates independently.

Example:

| Time | Hydration | Exercise | Full Access |
|------|-----------|----------|-------------|
| 09:30 | ✓ | incomplete but not yet due ✓ | ✓ |
| 10:00 (exercise deadline passes) | ✓ | ✗ | ✗ |
| 10:15 (workout completed) | ✓ | ✓ | ✓ |
| 10:30 (hydration timer expires) | ✗ | ✓ | ✗ |

The system should always be able to explain exactly which Gate or Gates currently prevent access.

---

## 20. Warnings

Earned may warn users before enforcement begins.

Warnings are configurable per Gate.

Examples:

> 💧 Hydration Gate closes in 10 minutes.
>
> 🏃 Workout due in 30 minutes.

Warnings provide information.

They do not create grace periods.

When the deadline arrives, the Gate changes state.

---

## 21. Overrides

Real life occasionally makes honoring a commitment unreasonable.

Earned therefore requires an escape hatch.

But an Override must not become a convenient alternative to completing the commitment.

There are three conceptually different Overrides.

---

## 22. Earned Override

Consistency can earn autonomy.

Some Gates may participate in a reward system.

Example:

> Complete X consecutive exercise commitments.
>
> Earn: 🎟️ 1 Free Override

A Free Override is genuinely free.

The user taps it.

The relevant obligation is cleared.

No approval. No waiting. No explanation. No shame flow.

The user earned it.

Patrick's Hydration Gate does not participate in rewards.

Patrick's Exercise Gate does.

Reward participation is configured per Gate.

Potential maximum stored Free Overrides: **2**

Exact reward thresholds should be determined later rather than prematurely fixed.

### Earned means earned

A Free Override is created by an explicit, immutable event at the moment it is
earned. It is never recomputed from history.

Changing the reward policy therefore affects **future earning only** — lowering
the streak threshold cannot retroactively mint rewards for completions already
in the past.

And because an easier reward policy is itself an escape route, easing it follows
the same rule as loosening restrictions: **stricter is allowed anytime; easier
requires Full Access and no hardened, unresolved commitment.**

---

## 23. Accountability Override

When no Free Override is available, the preferred escape route involves another human.

Users may nominate accountability partners.

Potential maximum: **5 people.**

When requesting an Override:

1. The user initiates an Override request.
2. Earned warns that accountability partners will be notified.
3. All designated partners receive the request.
4. A configured number must approve it.
5. If the threshold is reached, the Override succeeds.

Patrick's likely configuration: **2 approvals required.**

The threshold should be configurable when the commitment/accountability policy is created.

### MVP mechanism

Accountability partners do not need the app or accounts.

An Override request sends each partner a link over iMessage/SMS; the link opens a minimal approve/deny page backed by a lightweight backend.

Richer partner experiences (in-app approvals, partner profiles) come later.

---

## 24. Accountability Context

An accountability partner should receive enough information to make an informed decision.

Example:

> **Patrick is requesting an Override**
>
> Commitment: Run 30 minutes
>
> Progress: 18 / 30 minutes
>
> Recent reliability:
> - 8 of last 10 commitments completed
> - 2 Override requests in the last 30 days
> - 1 missed commitment in the last 30 days
>
> Reason: Optional
>
> [Approve] [Deny]

A user is never required to explain why they need an Override.

Some circumstances are private.

---

## 25. Solo Emergency Override

A user must ultimately retain a way to regain control without another person.

However, this is the final escape route.

The Solo Override is unavailable until the Accountability Override waiting period has elapsed without sufficient approvals.

Example:

> Accountability window: 30 minutes.
>
> Only after those 30 minutes may the Solo Override begin.

The Solo Override should involve meaningful active friction.

It should not merely be:

> Wait ten minutes while doing something else.

The user should have to actively complete the process.

**Elapsed time alone never completes a Solo Override.** A solo override requires
two things at once:

- **Effort** — measurable progress the user actually produces, accumulated as
  explicit acts.
- **A time floor** — a minimum elapsed period, so the effort cannot be spammed
  through in seconds.

Neither half is sufficient on its own. The requirement is frozen when the
challenge starts, so an edit made mid-challenge cannot make an in-flight escape
cheaper.

Initial conceptual target: **at least ~10 minutes of engaged effort.**

*The exact on-screen mechanic remains an open product-design surface.* What is
settled is that the domain requires produced effort, so the mechanic can be
replaced without touching the rules.

Repeated Solo Overrides should become increasingly inconvenient.

Illustrative escalation:

- 1st recent solo override → ~10 minutes
- 2nd → ~30 minutes
- 3rd → ~60 minutes

Exact mechanics require product design and abuse testing.

The important principle is:

**Repeated escape should not become a learned shortcut.**

---

## 26. Override Rules Are Commitments Too

Override policy is part of the hardened contract.

A locked user cannot simply change:

> 2 approvals required → 0

or:

> 30-minute accountability window → immediate solo override.

Doing so would make the commitment system meaningless.

Escape rules therefore harden alongside the commitment.

---

## 27. Rewards and Trust

Earned should gradually recognize demonstrated reliability.

A user who repeatedly honors commitments may earn flexibility.

This creates an important psychological distinction.

Earned does not say:

> "You can never be trusted."

It says:

> "You chose the rules. Keep proving you can honor them."

Reliability can earn autonomy.

Autonomy can eventually make enforcement unnecessary.

---

## 28. Onboarding

First launch should teach Earned's mental model through guided setup.

One concept per screen.

Example journey:

1. What Earned does
2. Choose Essential Access
3. Choose Earned Access
4. Create Hydration Gate
5. Create first Exercise commitment
6. Configure verification
7. Configure accountability
8. Configure Override rules
9. Review
10. Activate Earned

After onboarding, users should not repeatedly navigate this complexity.

---

## 29. Home

The Home screen answers one question:

**What do I need to do right now?**

Example:

> **Today**
>
> 💧 Water — Good — Locks again in 42 min
>
> 🏃 Exercise — Workout overdue — Any Apple Health workout
>
> **Phone Status:** 🔒 Restricted
>
> **Upcoming**
>
> Saturday — Run 30 min — Due 10:00 AM
>
> \+ New Commitment

The Home screen should remain intentionally sparse.

---

## 30. Navigation

The initial information architecture may include:

**Today** — Current Gates, status and immediate obligations.

**Calendar** — Upcoming and historical commitments.

**Trends** — Behavior over time. Potential metrics:

- commitments completed;
- completion rate;
- Gates missed;
- current/longest streaks;
- Overrides requested;
- Free Overrides earned;
- Free Overrides used;
- Accountability Overrides;
- Solo Emergency Overrides;
- average lateness;
- workout consistency.

**Settings** — Gate configuration, essential apps, accountability people, verification preferences and other system controls.

---

## 31. Product Personality

Earned is:

**Firm but playful.**

It is not:

- preachy;
- parental;
- clinical;
- aggressive;
- inspirational;
- guilt-heavy;
- wellness-corporate.

Earned should occasionally acknowledge the absurdity of negotiating with yourself.

Examples:

> Still locked.
>
> You said 30 minutes. You've done 18.
>
> 12 to go.

Or:

> Nice try.
>
> The deal still stands.

The personality should never obscure the current requirement.

**Clarity beats cleverness.**

---

## 32. Cross-Device North Star

Commitments belong to the person/account, not to a particular device.

The eventual model is:

**Account-level state → device-level enforcement.**

If the user owes a workout, every enrolled device should understand that state.

Future target devices include:

- iPhone
- iPad
- Mac

Example:

> Patrick owes a workout.
>
> Instagram is restricted on iPhone.
>
> Opening Instagram in a browser on Mac should not become an escape route.
>
> Complete the workout.
>
> Account Gate changes to satisfied.
>
> All enrolled devices update.

Earned should therefore avoid an architecture in which the iPhone is permanently assumed to be the canonical owner of commitment state.

---

## 33. Enforcement Integrity and Circumvention

Earned is a **voluntary commitment device**. The user chooses the commitment and
the consequence in advance, while thinking clearly.

Apple deliberately allows an adult to revoke a third-party app's Screen Time
authorization, or to delete the app. **Earned does not claim to be technically
inescapable, and must never imply otherwise.**

### Two separate states

The product tracks two things that must never collapse into one binary:

| | |
|---|---|
| **Gate state** | satisfied / unsatisfied — decided by the ledger alone |
| **Enforcement integrity** | available / unavailable — whether Earned currently holds OS authority to impose the consequence |

They combine, they do not merge:

- Gate unsatisfied + enforcement available → **restricted and enforced**
- Gate unsatisfied + enforcement unavailable → **still owed, but Earned cannot currently enforce**
- Gate satisfied → no restriction from that Gate, however enforcement stands

A workout is overdue. The Gate stays unsatisfied until the workout is completed
or legitimately overridden. If the user revokes Screen Time authorization, the
Gate **does not become satisfied**. The obligation remains in the ledger. What
changed is only Earned's ability to impose the OS-level consequence.

**The ledger remains the source of truth.**

### Overrides and bypasses are different things

An **Override** means the obligation was legitimately resolved through an
allowed escape path — free, accountability, or solo.

An **Enforcement Bypass** means Earned lost the ability to enforce the
consequence while the obligation remained unresolved.

These stay semantically distinct forever. A bypass must never:

- mark a commitment complete
- clear workout debt
- consume a Free Override
- silently forgive an obligation

### Consequence of a detected bypass

Where Earned can reliably determine that enforcement was removed while a
hardened Gate was unsatisfied, it will:

- record the bypass in history
- preserve the original obligation exactly as it stood
- break the relevant completion streak
- count the bypass in behavioural trends

It deliberately does **not** add further workout debt. Consequences should
increase accountability, not create hopelessness. Earned preserves what was
originally owed; it does not multiply obligations because the user failed. A
self-reinforcing debt trap makes the product unusable and is not accountability.

Bypass consequences should remain configurable, so stronger ones can be chosen
later — notifying accountability partners, raising the next Solo Override
escalation, or other user-selected costs.

### Accountability bypass alerts (future)

A user may opt in, **while in a non-compromised state**, to having accountability
partners notified when Earned detects a bypass during an active obligation:

> Patrick disabled Earned enforcement while a workout was overdue.

The user must not be able to disable this consequence by means of the bypass
itself.

### Identity and account circumvention

Creating a new account, logging out, reinstalling, or switching identity should
eventually be an ineffective or meaningfully inconvenient way to erase active
obligations.

This is **not** a promise of one human = one account, and no invasive identity
verification is intended. The requirement is narrower and sufficient:

**A new identity must not be an easier way out than the Override system.**

Account-authoritative state and device-local enforcement state both help.

### Hardening your own escape routes

Earned should teach users to make their own bypass deliberate rather than
reflexive, and recommend — never require — an Apple Screen Time passcode the
user cannot casually reach for: held by an accountability partner, stored
somewhere inconvenient, or random and unmemorised.

Earned must never collect, know, store, transmit or recover that passcode. Where
Apple does not expose whether a passcode exists, Earned must not infer or invent
that state.

### Desired behaviour vs OS-enforceable reality

These are recorded separately and honestly:

| Desired | OS-enforceable today |
|---|---|
| An active commitment is not escapable by revoking enforcement | **No.** Revocation always succeeds; Earned can only notice afterwards |
| Earned learns immediately that authorization was revoked | **No.** iOS does not notify a backgrounded app; the authorization publisher stays silent. Detection happens when Earned next runs |
| Earned knows *when* revocation happened | **No.** Only when it was detected |
| Earned knows revocation was deliberate | **No.** Intent is never provable; events are named for detection, not intent |
| Deleting and reinstalling does not erase debt | **Not yet.** State is device-local; this needs account-authoritative state |

Technical limitations are documented explicitly rather than hidden behind
guarantees Earned cannot keep.

---

## 34. Privacy

Earned will potentially process sensitive behavioral information.

The product should follow a minimum-knowledge principle.

- Accountability partners see only the information necessary to evaluate an Override.
- Health data should be accessed only to verify commitments the user explicitly created.
- Earned should not become a general health surveillance platform merely because HealthKit access exists.
- A user's restricted application selections should be handled using the most privacy-preserving mechanisms available.

---

## 35. MVP

The first build exists to answer one question:

**Does Earned materially change Patrick's behavior?**

It does not need to prove that Earned can become a global consumer product.

**MVP should target:** iPhone first.

### MVP Gates

**Hydration**

- rolling configurable timer;
- configurable active-hours window;
- self-attested completion;
- hard restriction when expired.

**Exercise**

- manually scheduled commitments;
- deadline;
- Apple Health workout verification;
- persistent non-compounding debt;
- hard restriction after missed deadline.

### MVP Access

- user-selected restricted applications/websites where technically feasible;
- user-selected essential applications;
- shielding while any Gate is unsatisfied.

### MVP Commitment Rules

- correction window (capped for short-fuse commitments);
- hardened commitments;
- harder-only edits;
- configurable warnings.

### MVP Overrides

- Free Overrides earned by consecutive completed exercise commitments;
- lightweight Accountability Overrides: partners approve or deny via a link sent over iMessage/SMS, no partner app or accounts, minimal backend;
- Solo Emergency Override with escalating friction, available only after the accountability window elapses.

### MVP UX

- guided onboarding;
- Today dashboard;
- simple lock/shield explanation;
- basic commitment creation;
- basic history.

---

## 36. Probably Not MVP

Unless implementation proves unexpectedly trivial, the first usable build does not require:

- Mac application;
- iPad synchronization;
- sophisticated heart-rate fraud detection;
- complex workout programming;
- accumulated workout debt;
- advanced analytics;
- social feeds;
- leaderboards;
- public profiles;
- AI coaching;
- automatic workout-plan generation;
- generalized productivity commitments;
- commercial billing;
- sophisticated reward economies.

The product should first prove the behavioral loop.

---

## 37. Future Product Surface

Earned's architecture should nevertheless leave room for richer commitments.

Examples:

**Fitness**

- Run 5 km.
- Lift for 30 minutes.
- Cycle 10 miles.
- Complete three workouts this week.

**Health behavior**

- Drink water.
- Take a walk.
- Potentially other user-defined behaviors where reliable verification exists.

**Productivity**

- Write for 30 minutes.
- Study for an hour.
- Finish a task.
- Read for 20 minutes.

The deeper abstraction is:

**Commitment → Evidence → Gate state → Access**

Earned should not implement all of these initially.

It should avoid architectural assumptions that make them impossible later.

---

## 38. What Earned Is Not

Earned is not primarily:

**A Screen Time tracker.** The goal is not merely telling users they spent four hours on Instagram yesterday.

**A fitness app.** It may verify exercise, but it does not need to design workouts.

**A hydration tracker.** Water volume is irrelevant to the initial behavioral objective.

**A habit checklist.** Checking a box without consequences misses the point.

**A motivational coach.** The user already decided what matters.

**A punishment engine.** Restrictions are consequences the user voluntarily chose.

---

## 39. Product Invariants

These rules should survive feature debates.

1. **Commitments are voluntary before they harden.** Earned does not decide what the user should do.
2. **Hardened commitments cannot become easier without an Override.** This is the foundation of trust in the system.
3. **Harder is always allowed.** Users may voluntarily strengthen their own commitment.
4. **Every active Gate must be satisfied for Full Access.** No Gate silently overrides another, and what is restricted is the union of what the unsatisfied ones take.
5. **Missed commitments persist.** Time passing alone does not forgive debt.
6. **MVP workout debt does not compound.** Maximum debt is one.
7. **Essential functionality remains accessible.** Earned restricts optional consumption, not basic participation in life.
8. **Consequences beat nagging.** Earned may warn, but enforcement is the mechanism.
9. **Overrides exist but cannot become the easiest path.** Except Free Overrides, which are genuinely earned.
10. **The system must always explain why something is locked.** No mysterious restrictions.
11. **Account state is conceptually authoritative.** Devices enforce commitments; they do not independently define them.
12. **Privacy is proportional to verification.** Collect only what the contract requires.
13. **The product should eventually make itself unnecessary.** Habit formation beats retention.
14. **A workout counts only inside its commitment's own window.** No reaching forward into a day that has not arrived; late workouts still reach back to clear debt.
15. **Escape must cost effort, not patience.** Waiting out a clock is not an override.
16. **An earned reward stays earned.** Policy changes are never retroactive, in either direction.
17. **Loss of enforcement authority never resolves an obligation.** Disabling Screen Time access, logging out, deleting, reinstalling or switching identity is never equivalent to completing or overriding a commitment.
18. **A bypass is not an Override.** One left the obligation standing; the other resolved it. History must always be able to tell them apart.
19. **Consequences increase accountability, not hopelessness.** Earned preserves what was originally owed rather than multiplying obligations because the user failed.
20. **A new identity must not be an easier way out than the Override system.**
21. **Earned never claims to be inescapable.** Where the OS permits circumvention, the product says so plainly.

---

## 40. The First User

The first user is Patrick.

Current problem:

Activity has fallen substantially following major changes in daily life and routine.

Exercise now competes directly with scarce personal leisure time.

The immediate goal is not athletic optimization.

It is rebuilding consistency.

### Initial Earned configuration

**Hydration**

- Requirement: Drink some water.
- Verification: Self-attestation.
- Interval: 60 minutes rolling.
- Reward eligible: No.

**Exercise**

- Requirement: Any qualifying workout.
- Verification: Apple Health workout record.
- Schedule: User creates exercise commitments as needed.
- Deadline: Selected when commitment is created.
- Debt: Persistent, maximum 1.
- Reward eligible: Yes.

**Restricted Access** — initial candidates:

- Instagram
- games, including Balatro
- YouTube
- ChatGPT / AI applications
- Safari
- Chrome
- Deliveroo
- other optional entertainment/social applications selected by the user

**Essential Access** — initial candidates:

- Phone
- Messages
- email
- Maps
- Citymapper
- Spotify
- other necessary communication/navigation/workout utilities

The exact application lists remain user-controlled.

---

## 41. Initial Success Test

The first version does not need sophisticated growth metrics.

For the first user, ask, after six weeks:

- Is exercise occurring more consistently?
- Is the user drinking water more reliably?
- Are missed exercise commitments eventually completed?
- Are restrictions changing behavior rather than merely causing frustration?
- How often are Overrides used?
- Does the user attempt to circumvent Earned?
- Which restrictions feel essential?
- Which feel unnecessarily disruptive?
- Does Earned reduce the mental negotiation required to begin exercise?
- Does the user still voluntarily create new commitments?

The most important qualitative question:

**When Earned locks something, do I actually go do the thing?**

If yes, the core loop works.

---

## 42. The Earned Test

Every proposed feature should face one question:

**Does this make it easier for a person to honor a commitment they deliberately made earlier?**

If yes, investigate it.

If it merely makes Earned more engaging, more social, more addictive, or better at retaining users without improving that outcome, question why it exists.

Earned should not solve distraction by becoming another distraction.

---

## 43. One-Sentence Product Definition

**Earned lets you voluntarily put distracting parts of your digital life behind commitments to yourself, then keeps them there until you do what you said you would do.**

---

## 44. The Promise

You decide what matters.

You decide the rules.

You decide what you're willing to give up if you don't follow through.

Then Earned remembers the deal when you would rather forget it.

**Do what matters first. Earn the rest.**
