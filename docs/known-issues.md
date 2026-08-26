# Known issues

Things we know are wrong, or are deliberately narrower than they look,
written down so nobody has to rediscover them from the code. Each entry
says what somebody would observe, why it is that way, and what would
have to change.

A fixed entry stays here with its date. The value of this file is that
it is a record of decisions, not a to-do list — the second time somebody
asks "why can't I connect an existing app", the answer is here rather
than in a commit message.

---

## KI-01 · The app name could not be changed when an existing app was chosen

**Status:** fixed, 2026-08-25 · **Raised by:** Gareth

**What happened.** The Set up form used to have a question between the
workspace and the name — "new app, or one you already have" — listing
the platform apps in the selected workspace. Choosing one of them wrote
that app's key into the app name field and made the field read-only.

**Why it was wrong.** It was written as a safety rail: a project folder
connected to an existing app should carry that app's name, and letting
the two drift means a folder that points at a different app from the one
it was joined to. That reasoning holds for the *platform* app key. It
does not hold for the name a person reads, and the field it locked was
the one people most want to change. A form that fills in an answer and
then refuses to let you edit it reads as broken, not as careful.

**What changed.** The question is gone entirely (see KI-02), so the lock
went with it. The name field is now always editable, and the form is the
three questions of the tested design: workspace, name, location.

**If the question ever comes back**, the app key and the display name
have to be two different things. The key stays fixed and invisible; the
name stays typed.

---

## KI-02 · The installer cannot connect a project to an app that already exists

**Status:** by design, 2026-08-25 · **Decided by:** Gareth

**What somebody would observe.** There is no way in EAI Setup to point a
new local project at an EAI app that already exists on the platform. It
creates a new app, from the EAI template, every time.

**Why.** Scope. EAI Setup is the front door for somebody who has nothing
yet: the template is the only app type it offers, so "which app?" had one
real answer and asking it was asking somebody to confirm a decision they
were never given. It also cost a question on the one screen the tested
design keeps to three.

**What it costs.** Anyone who already has an app and wants a local
project for it cannot get one from the installer. Today they use the
CLI directly: `eai init <name> --app-key <key> --company-tenant <id>`.

**What would have to change to bring it back.** The UI question, and
KI-01's separation of key from name. The plumbing is all still there —
`run_bootstrap` takes an `appKey`, the CLI takes `--app-key`, and
`get_company_apps` still works. Nothing was deleted below the form.

---

## KI-03 · "Copy the sign-in link" cannot appear

**Status:** open, needs a change in the `eai` CLI · **Found:** 2026-08-25

**What somebody would observe.** When the browser never comes back from
sign-in, the screen offers no link to paste in by hand — only a sentence
explaining what to do instead.

**Why.** `eai login` prints the authorize URL only when it is given an
explicit `--callback-port`. The installer does not pass one, so the URL
is never printed and there is nothing to copy. The installer's side is
already built: `bootstrap-signin-url` forwards the URL the moment it is
printed, and the button appears when one arrives.

**What would have to change.** `eai login` printing the URL
unconditionally, in the `eai` repo. The installer needs no change.

---

## KI-04 · The pre-login connectivity probe assumes one region

**Status:** open, low impact · **Found:** 2026-08-25

**What somebody would observe.** On a machine whose tenant lives outside
Australia, the sign-in screen's connectivity check probes
`api.au.myenterprise.ai` rather than that tenant's own API host.

**Why.** The CLI resolves its regional API URL *after* sign-in, from the
signed-in tenant. Before sign-in there is nothing to resolve from, so the
probe uses the same default the CLI itself falls back to.

**What it costs.** Almost nothing, deliberately: an unreachable probe
never blocks anything on its own. It raises the "cannot reach EAI"
failure, and the person retries; a wrong-region probe that succeeds is
also fine, because sign-in then finds out the truth. `BASE_URL_PUBLIC_API`
overrides the host for anyone who needs it.

---

## KI-05 · The harness screen's primary could sit below the fold

**Status:** fixed, 2026-08-25 · **Raised by:** Gareth

**What happened.** On *Choose how to work with AI*, in a 900×720 window,
the list could run long enough that **Next step** was below the visible
area until you scrolled — 108px under at worst, on the install failure.

**Why.** Anchored is not the same as visible. `margin-top: auto` puts
the rail at the bottom of the screen, and when the content above grows
past the window the rail goes with it. The three steps and the bar
across the top were each wanted; together they cost more than the screen
had spare.

**What changed.** Three things, all of which the hi-fi frames already
had:

1. **The rail is sticky**, so it is where anchored was aiming: the
   content scrolls under it and the primary is never off screen.
2. **Back moved into the rail.** The harness screen and the hand-off had
   a Back button above the title *and* an actions block below. The
   frames put Back on the left of the rail and nothing above the title,
   which is what the Set up screen already did.
3. **Check again sits beside the primary** rather than stacked above it.

Together those recovered enough that every state fits without scrolling
except the hand-off with a failed launch, which is 23px over — and there
the rail stays put, which was the point.

A hairline appears above the rail only when something is scrolling
underneath it. A rule under content that ends above it is a rule drawing
a box for no reason.

---

## KI-06 · "Setup details" is an addition, and undecided

**Status:** open, a decision to make · **Raised by:** Gareth, 2026-08-25

**What it is.** A shut disclosure along the bottom of every screen, with
a running record of what the installer actually did — each bootstrap
step, each safe summary line from the CLI, and every failure with the
message that came back. It replaced the old wizard's "Build summary"
panel.

**Why it is not obviously right.** It is not in the tested prototype and
it is not in the Paper frames. The app is meant to be seven screens and
nothing else, and this is an eighth thing on all of them. It also spends
most of its life saying **"nothing yet"** — a control advertising its
own emptiness — and it costs about 33px of every screen, on an app that
has run into fit problems twice in one afternoon.

**Why it might be.** It is the only record of what happened. When the
designed sentence is not enough — the one support call in fifty where
somebody needs to know which command failed and what it printed — there
is otherwise nothing to look at, and the alternative is asking a
non-technical person to reproduce it with a terminal open.

**Four ways to settle it, cheapest first:**

1. **Show it only once it has something to say.** Hidden while the
   record is empty, which removes the "nothing yet" frame entirely and
   costs nothing on the screens where it has nothing. A few lines.
2. **Show it only after a failure.** The record exists throughout;
   the strip appears when something has gone wrong.
3. **Move it off the screens.** Keep the record, reach it by keyboard
   shortcut or a menu item, so it costs no vertical space at all.
4. **Remove it.** The seven screens and nothing else. Support falls back
   to asking for the CLI's own output.

Nothing has been changed pending the decision. (1) is the smallest thing
that answers the specific frame this was raised against.

---

## KI-07 · The browser says "return to the terminal"

**Status:** open, needs a change in the `eai` CLI · **Found:** 2026-08-25

**What somebody would observe.** After signing in, the browser tab
shows a blank white page: "Login successful. Return to the terminal."
They are not in a terminal. They are in EAI Setup, which is already
telling them this window will continue by itself.

**Why.** `eai login` starts a localhost callback server and, on success,
responds with `text/plain`: "Login successful. Return to the terminal."
The installer cannot replace that page. It only runs `eai login`, and
must not bypass it.

**What it costs.** A moment of confusion at the one point where the
person is looking at the wrong window. The installer now says to close
the tab; the tab still says "terminal".

**What would have to change.** In the `eai` CLI, the callback response
should be HTML: signed in, close this tab, return to **Enterprise AI
Setup**. A CLI-only `eai login` can still mention the terminal. Optional:
close the tab after a few seconds. The installer needs no further change
once that ships.
