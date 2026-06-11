/* Experimental dictation patch for Terminal X.
 *
 * Loaded into every /tN/ page (via the sub_filter <script src>), but a NO-OP
 * unless the page was opened with ?kbdexp=1 (only term-x.html does that). On the
 * experimental terminal it takes over xterm's helper textarea: instead of xterm
 * streaming every keystroke/dictation-revision straight to the PTY (which makes
 * iOS dictation pile up), we BUFFER the textarea and forward a debounced
 * value-diff via xterm's coreService.triggerDataEvent — the same diff-on-settle
 * that works in the desktop relay. Printable keys, Enter, Backspace and Tab are
 * handled here; arrows/Ctrl/Esc/function keys fall through to xterm.
 *
 * Tap the "debug" button in term-x.html to toggle an overlay showing the raw
 * input/composition events, for diagnosing what iOS actually fires.
 */
(function () {
  if (location.search.indexOf('kbdexp') < 0) return;

  // ---- debug overlay (toggled by a postMessage from term-x.html) ----
  var dbgEl = null, dbgBuf = [];
  function dbg(s) {
    if (!dbgEl) return;
    dbgBuf.push(s); if (dbgBuf.length > 200) dbgBuf.shift();
    dbgEl.textContent = dbgBuf.join(''); dbgEl.scrollTop = dbgEl.scrollHeight;
  }
  window.addEventListener('message', function (e) {
    if (!e.data || e.data.type !== 'xdbg') return;
    if (dbgEl) { dbgEl.remove(); dbgEl = null; return; }
    dbgEl = document.createElement('div');
    dbgEl.style.cssText = 'position:fixed;top:0;left:0;right:0;max-height:34vh;overflow:auto;z-index:2147483647;background:rgba(0,0,0,.9);color:#6f6;font:11px ui-monospace,monospace;padding:6px;white-space:pre-wrap;word-break:break-all';
    document.body.appendChild(dbgEl); dbg('[term-x debug on] ');
  }, false);

  // Send raw bytes to the PTY (bypasses bracketed-paste so Enter executes).
  function sendRaw(d) {
    var t = window.term; if (!t) return;
    try {
      var cs = t._core && t._core.coreService;
      if (cs && cs.triggerDataEvent) cs.triggerDataEvent(d, true);
    } catch (_) {}
  }

  function patch(ta) {
    var lastSent = '', composing = false, timer = null;

    function flush() {
      timer = null;
      var v = ta.value;
      dbg(' {in=' + JSON.stringify(v) + ' last=' + JSON.stringify(lastSent) + '}> ');
      // iOS dictation transiently clears the field to "" between revisions —
      // ignore it so we stay pure-append and never emit stray deletes.
      if (v === '' && lastSent !== '') return;
      var i = 0, min = Math.min(v.length, lastSent.length);
      while (i < min && v.charAt(i) === lastSent.charAt(i)) i++;
      for (var d = lastSent.length - i; d > 0; d--) { sendRaw(String.fromCharCode(127)); dbg('<BS>'); }
      for (var j = i; j < v.length; j++) { sendRaw(v.charAt(j)); dbg(v.charAt(j)); }
      lastSent = v;
    }
    function sched(ms) { if (timer) clearTimeout(timer); timer = setTimeout(flush, ms); }
    function clr() { if (timer) { clearTimeout(timer); timer = null; } ta.value = ''; lastSent = ''; }

    // Capture-phase + stopImmediatePropagation suppresses xterm's own (bubble)
    // handlers so it doesn't double-send the text path. Control keys are NOT
    // blocked, so xterm still handles arrows/Ctrl/Esc/etc.
    ta.addEventListener('compositionstart', function (e) { dbg(' (cs)'); composing = true; e.stopImmediatePropagation(); }, true);
    ta.addEventListener('compositionend', function (e) { dbg(' (ce)'); composing = false; e.stopImmediatePropagation(); sched(40); }, true);
    ta.addEventListener('input', function (e) {
      dbg(' i[' + JSON.stringify(ta.value) + ' c=' + (e && e.isComposing) + ']');
      e.stopImmediatePropagation();
      sched((composing || (e && e.isComposing)) ? 400 : 80);
    }, true);
    ta.addEventListener('keydown', function (e) {
      var k = e.key;
      if (k === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); flush(); sendRaw(String.fromCharCode(13)); clr(); dbg(' <ENTER> '); }
      else if (k === 'Tab') { e.preventDefault(); e.stopImmediatePropagation(); sendRaw(String.fromCharCode(9)); dbg(' <TAB> '); }
      else if (k === 'Backspace') { e.stopImmediatePropagation(); }  // lets the textarea shrink → input diff sends DEL
      else if (k && k.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) { e.stopImmediatePropagation(); }  // printable → input diff
      // everything else (arrows, Ctrl/Alt combos, Esc, F-keys) → xterm
    }, true);
  }

  var iv = setInterval(function () {
    var ta = document.querySelector('.xterm-helper-textarea');
    if (ta && window.term) { clearInterval(iv); patch(ta); }
  }, 100);
})();
