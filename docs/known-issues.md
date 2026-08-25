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
