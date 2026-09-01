# Earned beta — what to try, and what should happen

Thanks for testing this. Earned is an app that takes apps away from you until you do the
thing you said you'd do. That is a strange thing to install, so this walks through it and
tells you what *should* happen at each step. Where something different happens, that is the
useful part — please tell us.

**You will not break anything.** Every restriction Earned applies can be lifted, and there
is a way out of every commitment even if nothing works. If you ever feel stuck, skip to
[If you get stuck](#if-you-get-stuck) at the bottom.

**Time needed:** about 20 minutes of attention, spread over an hour or two — one step is
"wait for a deadline to pass".

**Please pick something low-stakes to be blocked from.** A game, or a social app you can do
without for an hour. Not Messages, not your work email, not maps if you are about to drive
somewhere.

---

## How to report anything

In the app: **You** tab → **Beta** → **Report a problem**. It opens an email draft you can
read and edit before sending. Nothing is sent until you send it.

Please include, every time:

- **Which step below** you were on.
- **What you expected** and **what happened instead**.
- **A screenshot**, if there was anything on screen. You can attach it in the mail draft.
- Leave **"Include diagnostics" on** unless you'd rather not. It sends version numbers,
  which permissions you granted, and how many things are stored — never your commitments,
  your friends, your Health data, or anything that could sign anyone in as you. You can tap
  "See exactly what's included" to read it first.

If the app *crashes*, the report won't have a diagnostics attachment, so please just say
what you were doing when it went. If it happens repeatedly, that is exactly the kind of
thing worth an extra message.

---

## Step 1 — Install and open it

Tap the TestFlight link, install, open.

**Expected:** a series of short screens explaining Gates, water, restrictions, how you prove
you did a workout, and the ways out of a commitment. Read them — but also tell us if any
of them confused you. That is a real bug, not a nitpick.

**Tell us if:** any screen's wording made you unsure what you were agreeing to, or you
reached the end still not knowing what the app does.

## Step 2 — Let it block things

Somewhere in setup, iOS will ask to allow **Screen Time** access.

**Expected:** an Apple system sheet asking permission. Tap Allow.

**Expected if you tap Don't Allow:** the app keeps working and says plainly that it cannot
block anything. It should never claim a restriction is active when it isn't. If it does,
that is a serious bug — screenshot it.

**Tell us if:** the sheet doesn't appear at all, or you get an error mentioning "sandbox" or
"FamilyControlsAgent". Screenshot the error text.

## Step 3 — Sign in and pick a name

**Expected:** Sign in with Apple, then a screen to choose a handle (a unique name like
`@sam`) and optionally a photo.

**Expected if you cancel the sign-in:** everything local keeps working. Friends, shared
commitments and asking someone to let you off are the parts that need an account, and the
app should say so rather than showing empty screens.

**Tell us if:** a handle you typed was rejected without saying why, the screen spun forever,
or you saw a raw error message full of technical words.

## Step 4 — Let it read your workouts

**Expected:** at some point — probably when you make your first commitment — iOS asks to let
Earned read workouts from Apple Health. **Please allow it.** Apple Health is the only way a
finished workout gets into Earned, so if you refuse, nothing you do can complete a
commitment and the only way out is an Override.

**Expected if you refuse:** the app should say so. Check **You** → **Apple Health** — it
should say it isn't connected and offer to ask again. A commitment you can't complete should
say that on its own screen too.

**Tell us if:** you allowed Health access and a workout you definitely did still didn't
count. This is the single most important thing to report.

## Step 5 — Choose what gets taken away

**Expected:** **You** → **Restrictions**, then pick a Gate and choose apps in Apple's own
picker.

Pick **one** low-stakes app. Earned genuinely cannot see which app you picked — that is
Apple's design and Earned works within it — so screens count restrictions rather than naming
them. That is expected, not a bug.

**Tell us if:** you picked something and the count didn't change, or you couldn't find where
to pick.

## Step 6 — Make one short commitment

**Expected:** Today → the button to make a new commitment. Set it to something you are
*not* going to do, with a deadline about **30 minutes** away. We want the deadline to pass.

You will be asked what counts as done, when it's due, what gets blocked, and how you can get
out of it. At the end you should see something like a printed receipt: THE DEAL.

**Tell us if:** any question didn't make sense, or the deal at the end didn't match what you
chose.

## Step 7 — The important one: close Earned completely

This is the step we most need tested, because it is the whole idea of the app.

1. Swipe up from the bottom of the screen and **swipe Earned away** so it is fully closed.
   Not just on the home screen — actually closed.
2. **Keep using your phone normally.** Do not open Earned again.
3. Wait for the deadline you set to pass. (You'll probably get a warning notification a
   little before it.)
4. Once the deadline has passed, **try to open the app you chose to block** in Step 5.

**Expected:** the app you picked will not open. iOS shows a shield screen instead. This
should happen **without you opening Earned at all**.

**Tell us if — and this is the big one:** the blocked app opens perfectly normally after the
deadline has passed, and only starts being blocked once you open Earned. That is a bug we
need to know about immediately. Note roughly how long after the deadline you tried.

Also tell us if: it blocked *before* the deadline, or something you didn't pick got blocked.

## Step 8 — Do the thing, get let back in

Now actually do the workout you committed to — go for the run or the walk, recorded by your
watch or whatever app you normally use. Then open Earned.

**Expected:** the commitment shows as kept, and the app you picked works again.

**Tell us if:** you did the workout, Health has it, and Earned still shows the commitment as
outstanding. Screenshot the Earned screen *and* the workout in Apple Health.

## Step 9 — The ways out

Make a second short commitment (deadline 15 minutes away), let it pass, and try getting out
of it instead of doing it.

**Expected:** on Today, or on the red locked notice, tapping the commitment shows the ways
out: a free Override if you have one, and a "Solo Override" that becomes available after a
wait and then asks you to do something deliberate and slightly tedious. That tedium is on
purpose.

**Expected:** the Solo Override works **even in airplane mode**. Please try that — turn on
airplane mode and check that you can still get yourself out. If you can be stuck because
the internet is down, that is the most serious kind of bug this app can have.

**Tell us if:** you couldn't find any way out, or the Solo Override wouldn't finish, or
turning off the internet left you with no route at all.

## Step 10 — A friend

Needs a second person also testing.

**Expected:** Social tab → add a friend by their handle → they get a request → they accept →
you both see each other.

**Tell us if:** a search for a handle you know exists came back empty, or a request seemed to
send but never arrived, or a screen sat spinning.

## Step 11 — A commitment together

**Expected:** when making a commitment, choose to do it "with friends", pick your friend,
and they get an invitation. When they accept, they get their **own** commitment with their
own deadline and their own blocked apps — not a shared punishment. You can each see how the
other is doing against the same target.

**Tell us if:** the invitation never arrived, accepting did nothing, or one of you finishing
changed something for the other.

## Step 12 — Asking someone to let you off

**Expected:** nominate a friend as an accountability partner. **They have to say yes** — it
is not something you can do to someone. Once they've agreed, a commitment can be set up so
their approval lets you out early.

**Please note:** there are no push notifications in this build. Your partner will only see
your request **the next time they open Earned**. That is expected for now. Text them.

**Tell us if:** you nominated someone and they never saw anything even after opening the app,
or they approved and you were still locked, or you were let out of something *before* they
approved.

---

## Things we already know about

Not worth reporting — but tell us if any of them is worse than described:

- **Blocked apps show Apple's plain grey shield**, not an Earned-designed one.
- **No push notifications.** Anything involving another person waits until they open the app.
- **Inviting someone who doesn't have Earned isn't in this build.** Earned can't send the
  invitation yet, so rather than let you build a commitment on a partner who will never hear
  about it, the option says so and is switched off. Only friends who are also testing can be
  accountability partners.
- **Deleting and reinstalling Earned wipes your local commitments and any debt.** Do not do
  it as an escape route and then be surprised; do tell us if you did it by accident.
- **Turning off Screen Time access in iOS Settings turns enforcement off.** No app can
  prevent that. Earned notices the next time you open it and stops claiming to enforce.
- **There is no delete-account button.** Ask and it gets done by hand.

## If you get stuck

In order:

1. Open Earned, tap the commitment holding things shut, and use the **Solo Override**. It
   works offline and needs nobody's permission.
2. **iOS Settings → Screen Time → Apps With Screen Time Access → Earned → turn it off.** This
   removes every restriction immediately. It is always available and always will be — an app
   that could stop you doing this would be a much worse thing than a missed workout.
3. Delete the app.

None of these will get you in trouble. If you had to use 2 or 3, please tell us what led
there — that is a design failure on our end, not on yours.
