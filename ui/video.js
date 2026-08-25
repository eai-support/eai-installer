/* ------------------------------------------------------------------
   "Watch what happens next" — the hand-off, shown rather than told.

   An external AI tool opens empty and we cannot write a word into it,
   so the last thing a person reads is whatever we showed them before
   they left. This is the second half of saying it: a still instruction,
   and then a moving one for anyone the still one lost.

   It plays in place, at full size. A thumbnail asks to be skipped and a
   modal asks permission to take over the screen; this is the size it
   will be when it is running, whether or not anyone presses it.

   It is drawn rather than filmed. A real screen recording would date
   the moment any of these tools changes its chrome, and this has to
   survive that — the installer ships on a release cadence measured in
   weeks and the tools it hands over to change theirs more often.

   Ported from the prototype's assets/eai-video.js. The one change: the
   caption no longer claims a duration the clip does not have.
------------------------------------------------------------------- */

(function registerVideo(root) {
  const SCRIPT = [
    { at: 0, caption: "Your app opens in your AI tool — empty." },
    { at: 1500, caption: "Type /eai at the prompt.", type: "/eai" },
    { at: 4200, caption: "Press enter.", enter: true },
    { at: 5200, caption: "That's it — EAI takes over from there.", done: true },
  ];

  const TOTAL = 6400;
  const IDLE = "Watch what happens next";

  const MARKUP = `
    <div class="eai-vid-stage">
      <div class="eai-vid-win">
        <div class="eai-vid-bar"><i></i><i></i><i></i><span class="eai-vid-title"></span></div>
        <div class="eai-vid-body">
          <span class="eai-vid-line"><em>&#10095;</em><b class="eai-vid-typed"></b><s class="eai-vid-caret"></s></span>
          <span class="eai-vid-ok" hidden>&#10003; EAI is running. Tell it what you want to build.</span>
        </div>
      </div>
      <button class="eai-vid-play" type="button" aria-label="Play">
        <svg viewBox="0 0 24 24" fill="none"><path d="M8 5.5v13l11-6.5z" fill="currentColor"/></svg>
      </button>
    </div>
    <div class="eai-vid-ft">
      <span class="eai-vid-caption"></span>
      <div class="eai-vid-track"><i></i></div>
    </div>`;

  /**
   * Turn a container into an inline player.
   *
   * Safe to call again on the same element: the markup is replaced and
   * the timers of the previous mount are dropped with it, which matters
   * because the hand-off screen is repainted every time somebody goes
   * back and picks a different tool.
   */
  function mountVideo(element, { app, project } = {}) {
    if (!element) return;
    element.classList.add("eai-vid");
    element.innerHTML = MARKUP;

    const stage = element.querySelector(".eai-vid-stage");
    const title = element.querySelector(".eai-vid-title");
    const typed = element.querySelector(".eai-vid-typed");
    const caret = element.querySelector(".eai-vid-caret");
    const ok = element.querySelector(".eai-vid-ok");
    const play = element.querySelector(".eai-vid-play");
    const caption = element.querySelector(".eai-vid-caption");
    const progress = element.querySelector(".eai-vid-track i");

    // The window in the film is the one they are about to be handed to.
    const appName = app || element.dataset.app || "your AI tool";
    const projectName = project || element.dataset.project || "your app";
    title.textContent = `${appName} — ${projectName}`;
    caption.textContent = IDLE;

    let timers = [];
    let tick = null;

    function reset() {
      timers.forEach(clearTimeout);
      timers = [];
      clearInterval(tick);
      typed.textContent = "";
      caret.hidden = false;
      caret.classList.remove("flash");
      ok.hidden = true;
      progress.style.width = "0%";
      caption.textContent = IDLE;
      stage.classList.remove("playing");
      play.classList.remove("replay");
      play.setAttribute("aria-label", "Play");
    }

    function run() {
      reset();
      stage.classList.add("playing");

      const started = Date.now();
      tick = setInterval(() => {
        const fraction = Math.min(1, (Date.now() - started) / TOTAL);
        progress.style.width = `${fraction * 100}%`;
        if (fraction === 1) clearInterval(tick);
      }, 60);

      for (const beat of SCRIPT) {
        timers.push(setTimeout(() => {
          caption.textContent = beat.caption;
          if (beat.type) {
            // Typed one letter at a time, which is the whole point of showing it.
            [...beat.type].forEach((character, index) => {
              timers.push(setTimeout(() => { typed.textContent += character; }, index * 260));
            });
          }
          if (beat.enter) caret.classList.add("flash");
          if (beat.done) {
            caret.hidden = true;
            ok.hidden = false;
            // Back to a play button, so watching it twice is one click.
            stage.classList.remove("playing");
            play.classList.add("replay");
            play.setAttribute("aria-label", "Watch again");
          }
        }, beat.at));
      }
    }

    play.addEventListener("click", run);
    // The whole frame is the target while it is idle — a small one is the
    // reason nobody pressed the version of this that was a thumbnail.
    stage.addEventListener("click", (event) => {
      if (event.target.closest(".eai-vid-play")) return;
      if (stage.classList.contains("playing")) return;
      run();
    });

    element.__eaiVideoReset = reset;
  }

  root.mountVideo = mountVideo;
})(typeof window === "undefined" ? globalThis : window);
