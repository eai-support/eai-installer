/* ------------------------------------------------------------------
   The hand-off, shown rather than told.

   An external AI tool opens empty and we cannot write a word into it,
   so the last thing a person reads is whatever we showed them before
   they left. The instruction sits above the player in one card; the
   film is the moving half for anyone the still one lost.

   It plays in place, at full size. A thumbnail asks to be skipped and a
   modal asks permission to take over the screen; this is the size it
   will be when it is running, whether or not anyone presses it.

   It is drawn rather than filmed. A real screen recording would date
   the moment any of these tools changes its chrome, and this has to
   survive that — the installer ships on a release cadence measured in
   weeks and the tools it hands over to change theirs more often.

   Ported from the prototype's assets/eai-video.js.
------------------------------------------------------------------- */

(function registerVideo(root) {
  const SCRIPT = [
    { at: 0 },
    { at: 1500, type: "/eai" },
    { at: 4200, enter: true },
    { at: 5200, done: true },
  ];

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

    // The window in the film is the one they are about to be handed to.
    const appName = app || element.dataset.app || "your AI tool";
    const projectName = project || element.dataset.project || "your app";
    title.textContent = `${appName} — ${projectName}`;

    let timers = [];

    function reset() {
      timers.forEach(clearTimeout);
      timers = [];
      typed.textContent = "";
      caret.hidden = false;
      caret.classList.remove("flash");
      ok.hidden = true;
      stage.classList.remove("playing");
      play.classList.remove("replay");
      play.setAttribute("aria-label", "Play");
    }

    function run() {
      reset();
      stage.classList.add("playing");

      for (const beat of SCRIPT) {
        timers.push(setTimeout(() => {
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
