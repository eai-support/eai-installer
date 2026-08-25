# The statemachine

Every state EAI Setup can be in, on one page, with a rail to reach them.

```bash
npm run prototype
```

Then open **http://localhost:4321/** — that is the statemachine. It is
the only address you need; the app on its own is a link inside the page.

**Leave the tab open.** The server watches `ui/`, `prototype/` and
`tauri.conf.json` and reloads any tab it is serving when one of them
changes, so a change lands in front of you without a refresh and without
restarting anything. Running it a second time says so rather than
failing on the port.

The reload client is added to HTML *responses*, never to the files, so
nothing on disk knows the server exists and `ui/` is bundled exactly as
it is written — `npm test` fails if any of it ever lands in a file.

This is a review tool. It is **not** in the release: Tauri bundles `ui/`
and nothing else, and `scripts/test-ui-contract.mjs` fails the build if
anything named like this folder ever appears inside `ui/`.

## What it is

The panel on the right is `../ui/index.html` in a frame — the real app,
rendering itself, in preview mode where every Tauri call is stubbed. The
rail on the left does one thing: it builds the query string the
installer already understands and points the frame at it.

So there is **no second copy of any screen in this folder**. Change
`ui/`, reload the page, and the change is here. The screens, the ways
each of them can break, which failures can happen together, and the
sentence describing each state all come from `ui/state-machine.js`; the
rail asks that module what the questions are rather than listing them.
Add a screen or a failure to the app and it appears here on the next
reload without anybody editing `rail.js`.

Two things follow from that, and both are checked by `npm test`:

- A parameter the app reads that the rail cannot set is a state nobody
  can review.
- A parameter the rail sets that the app ignores is a control that does
  nothing.

## The rail

Ported from the prototype's own `assets/states.css` and its `renderRail`
— same class names, same shapes, same reasoning. The options are not
boxed, because the chosen one is simply the one you can read and the
rest are still there. The failures carry a square when they combine and
a circle when they cannot, so the difference is read rather than
discovered by clicking. `npm test` fails if any of that drifts back.

Two things differ from the original and both are forced: it uses system
fonts rather than fetching Geist from Google, and the frame carries the
shadow because an iframe cannot be styled from outside.

## What the rail asks

| Group | Question | Where it applies |
| --- | --- | --- |
| Screen | Which of the seven | everywhere |
| State | Working, or which specific failure | everywhere |
| This computer | macOS, Windows or Linux | first, and everywhere — it changes the wording of every screen rather than which one you see. A tab group, because there will not be a fourth |
| Answered so far | How far the form has been revealed | Set up |
| This account | One workspace or two, with apps or without | Set up |
| Before anyone presses anything | The quiet fix-up, mid-run; the Mac password | Sign in |
| Which one | Which prerequisites failed — checkboxes, under the failure they belong to, because more than one can | Sign in, when broken |
| The moment | Signed in, waiting, or waiting long enough to worry | Signed in |
| How far it has got | Which of the four rows is running or failed | Creating |
| AI tools on this computer | Nothing, one, two, or all of them | Choose a harness, Hand-off, Built |

Two failures can be ticked at once where the screen says they can
co-occur — sign-in is the one that matters, because a managed machine
that would not let Git install is often the same one that cannot reach
the EAI API, and the screen that has to hold both is a different screen
from either alone.

`←` and `→` step through the screens in order. The address bar holds the
state you are looking at, so a state worth discussing is a link rather
than four instructions — copy it from there.

## What it cannot show you

Everything that needs a real machine, which is most of what can actually
go wrong:

- the real macOS password prompt and whether Apple's installer accepts it
- a real `eai login` round trip, and what the CLI actually prints
- a real `eai init`, and how long each row really takes
- the harness waiting poll finding a tool that has genuinely just landed
- how any of it looks on Windows or Linux, in their own webviews

Preview mode stubs every one of those. Use this to review what the
screens say and when; use a real build to find out whether they are
true.

## Related

- `ui/state-machine.js` — the screens, the faults, and every sentence
- `docs/scenario-matrix.md` — what has to be true, with IDs
- The shared design source: `prototypes/statemachine`, which does the
  same thing for the web sign-up flow
