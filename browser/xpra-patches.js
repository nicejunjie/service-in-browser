/**
 * Patches for xpra HTML5 client.
 * Injected via nginx sub_filter. Designed to degrade gracefully if
 * xpra's API changes — each patch is wrapped in try/catch.
 */
(function() {
  'use strict';

  // Shared client-side view zoom — Safari-style magnification of the rendered
  // canvas (same remote layout, just bigger pixels + pan), applied as a CSS
  // transform on #screen (see patch 4). getMouse (patch 1) divides click
  // coordinates by .z so taps still land correctly while magnified.
  var VIEWZOOM = { z: 1, px: 0, py: 0, min: 1, max: 6 };

  // Shared keyboard hooks — patch 3 builds the hidden native input and assigns
  // these; the touch layer (patch 4) calls them to raise/dismiss the keyboard
  // on tap/two-finger-tap, so there's no on-screen keyboard button.
  var kbdFocus = null, kbdBlur = null, kbdLastBlur = 0;
  var kbdSendChar = null, kbdSendKey = null;   // exposed by patch 3 for paste (patch 5)

  // 0. Suppress "leave site?" confirmation on refresh/close.
  try {
    window.onbeforeunload = null;
    Object.defineProperty(window, 'onbeforeunload', { get: function() { return null; }, set: function() {}, configurable: true });
    var origAEL = window.addEventListener.bind(window);
    window.addEventListener = function(type) {
      if (type === 'beforeunload') return;
      return origAEL.apply(null, arguments);
    };
  } catch(e) {
    console.warn('[xpra-patches] beforeunload patch failed:', e.message);
  }

  // 1. Mouse offset fix: getMouse uses clientX/clientY (viewport coords)
  //    but the canvas may not start at (0,0). Patch to use canvas-relative coords.
  try {
    var P = XpraClient.prototype;
    var origGM = P.getMouse;
    P.getMouse = function(e) {
      var r = origGM.call(this, e);
      if (e.target && e.target.getBoundingClientRect) {
        var b = e.target.getBoundingClientRect();
        // b reflects the CSS view-zoom transform, so divide the offset by the
        // zoom factor to recover real canvas coordinates (z=1 → unchanged).
        var z = VIEWZOOM.z || 1;
        r.x = this.last_mouse_x = Math.round((e.clientX - b.left) / z * (this.scale || 1));
        r.y = this.last_mouse_y = Math.round((e.clientY - b.top) / z * (this.scale || 1));
      }
      return r;
    };
  } catch(e) {
    console.warn('[xpra-patches] getMouse patch failed:', e.message);
  }

  // 2. Scroll fix: xpra's default scroll handler accumulates wheel deltas
  //    to 120 units before sending, which makes slow trackpad scrolling
  //    unresponsive. Replace with immediate per-event dispatch.
  try {
    var P = XpraClient.prototype;
    P.on_mousescroll = function(e, win) {
      if (this.server_readonly || this.mouse_grabbed || !this.connected || (!win && this.server_is_shadow))
        return false;
      var mouse = this.getMouse(e);
      var mx = Math.round(mouse.x), my = Math.round(mouse.y);
      var modifiers = this._keyb_get_modifiers(e);
      var wid = 0, coords = [mx, my];
      if (win) {
        wid = win.wid;
        var pos = win.get_internal_geometry();
        coords.push(Math.round(mouse.x - pos.x));
        coords.push(Math.round(mouse.y - pos.y));
      }
      var norm = Utilities.normalizeWheel(e);
      var dy = norm.pixelY, dx = norm.pixelX;
      // Cap clicks per event: a fast trackpad fling reports deltas in the
      // thousands, which would burst hundreds of packets down the (possibly
      // tunneled) websocket and lag everything behind them.
      var MAX_CLICKS = 10;
      if (dy !== 0) {
        var btn = dy > 0 ? 5 : 4;
        var n = Math.min(MAX_CLICKS, Math.max(1, Math.round(Math.abs(dy) / 30)));
        for (var i = 0; i < n; i++) {
          this.send([PACKET_TYPES.button_action, wid, btn, true, coords, modifiers, []]);
          this.send([PACKET_TYPES.button_action, wid, btn, false, coords, modifiers, []]);
        }
      }
      if (dx !== 0) {
        var btn = dx > 0 ? 7 : 6;
        var n = Math.min(MAX_CLICKS, Math.max(1, Math.round(Math.abs(dx) / 30)));
        for (var i = 0; i < n; i++) {
          this.send([PACKET_TYPES.button_action, wid, btn, true, coords, modifiers, []]);
          this.send([PACKET_TYPES.button_action, wid, btn, false, coords, modifiers, []]);
        }
      }
      e.preventDefault();
      return false;
    };
  } catch(e) {
    console.warn('[xpra-patches] scroll patch failed:', e.message);
  }

  // 3. Mobile keyboard — use the NATIVE iOS/Android keyboard instead of xpra's
  //    drawn `.simple-keyboard`, and with NO on-screen button: a 1-finger tap
  //    raises it (like the terminal), a 2-finger tap dismisses it (both wired
  //    in patch 4 via kbdFocus/kbdBlur). A hidden real <input> receives the
  //    native keyboard; each character typed is forwarded to the remote as a
  //    synthetic key event (the same channel xpra forwards — its handlers don't
  //    check isTrusted). We diff the input's value on every `input` event so
  //    backspace and autocorrect replacements work; Enter/Tab/empty-backspace
  //    go via keydown.
  try {
    var css = document.createElement('style');
    css.textContent =
      '.simple-keyboard{display:none!important}' +     // never show xpra's drawn keyboard
      // Hidden but focusable input. font-size:16px stops iOS zooming on focus;
      // kept invisible (opacity/transparent) rather than display:none, which
      // would block focus() from raising the keyboard.
      '#xpra-kbd{position:fixed;bottom:0;left:0;width:1px;height:1px;opacity:0;' +
        'border:0;padding:0;margin:0;font-size:16px;z-index:-1;' +
        'color:transparent;background:transparent;caret-color:transparent}';
    document.head.appendChild(css);

    var kbdInput = null, lastVal = '';

    // Dispatch a key press+release on document; xpra reads event.code / key /
    // keyCode to build the keysym (229 is the IME-composition sentinel — we
    // never send it, so real characters always go through).
    var sendKey = function(key, code, keyCode, shift) {
      ['keydown', 'keyup'].forEach(function(type) {
        document.dispatchEvent(new KeyboardEvent(type, {
          key: key, code: code || '', keyCode: keyCode || 0, which: keyCode || 0,
          shiftKey: !!shift, bubbles: true, cancelable: true
        }));
      });
    };
    var sendChar = function(ch) {
      var code = '', kc = ch.charCodeAt(0), shift = false, up = ch.toUpperCase();
      if (ch >= 'a' && ch <= 'z')      { code = 'Key' + up;  kc = up.charCodeAt(0); }
      else if (ch >= 'A' && ch <= 'Z') { code = 'Key' + ch;  kc = ch.charCodeAt(0); shift = true; }
      else if (ch >= '0' && ch <= '9') { code = 'Digit' + ch; kc = ch.charCodeAt(0); }
      else if (ch === ' ')             { code = 'Space'; kc = 32; }
      // Other symbols: leave code empty; xpra maps them from event.key.
      sendKey(ch, code, kc, shift);
    };
    var resetBuf = function() { if (kbdInput) kbdInput.value = ''; lastVal = ''; };

    // Diff the input value: deletions after the common prefix → Backspace,
    // the remaining new tail → forwarded char-by-char. Survives autocorrect
    // (which deletes a word then inserts the replacement).
    var onInput = function() {
      var v = kbdInput.value, i = 0, min = Math.min(v.length, lastVal.length);
      while (i < min && v.charAt(i) === lastVal.charAt(i)) i++;
      for (var d = lastVal.length - i; d > 0; d--) sendKey('Backspace', 'Backspace', 8);
      for (var j = i; j < v.length; j++) sendChar(v.charAt(j));
      lastVal = v;
      if (v.length > 80) resetBuf();   // keep the hidden buffer small
    };
    var onKeydown = function(e) {
      if (e.key === 'Enter')   { e.preventDefault(); sendKey('Enter', 'Enter', 13); resetBuf(); }
      else if (e.key === 'Tab'){ e.preventDefault(); sendKey('Tab', 'Tab', 9); }
      else if (e.key === 'Backspace' && kbdInput.value === '') {
        // Empty buffer → the diff sees no change; forward Backspace directly so
        // the user can keep deleting remote content past what they just typed.
        e.preventDefault(); sendKey('Backspace', 'Backspace', 8);
      }
      // printable keys + non-empty backspace are handled by onInput's diff
    };

    var build = function() {
      if (document.getElementById('xpra-kbd')) return;
      kbdInput = document.createElement('input');
      kbdInput.id = 'xpra-kbd';
      kbdInput.type = 'text';
      kbdInput.setAttribute('autocapitalize', 'off');
      kbdInput.setAttribute('autocomplete', 'off');
      kbdInput.setAttribute('autocorrect', 'off');
      kbdInput.spellcheck = false;
      kbdInput.addEventListener('input', onInput);
      kbdInput.addEventListener('keydown', onKeydown);
      kbdInput.addEventListener('blur', function() { kbdLastBlur = Date.now(); });
      document.body.appendChild(kbdInput);
      // Expose to the touch layer (patch 4): tap raises, 2-finger tap dismisses.
      kbdFocus = function() { resetBuf(); try { kbdInput.focus(); } catch (e) {} };
      kbdBlur  = function() { try { kbdInput.blur(); } catch (e) {} };
    };
    kbdSendChar = sendChar; kbdSendKey = sendKey;   // for the paste patch (5)
    if (document.body) build();
    else document.addEventListener('DOMContentLoaded', build);
  } catch(e) {
    console.warn('[xpra-patches] keyboard patch failed:', e.message);
  }

  // 4. Mobile zoom — Safari-style pinch magnification + visible +/− buttons.
  //    The parent desktop disables iOS's own pinch-zoom, so we implement it
  //    here as a CSS transform on #screen: the remote layout is UNCHANGED
  //    (no font/zoom keystrokes to Chromium), we just magnify the rendered
  //    canvas and let the user pan around it — exactly how Safari zooms a page.
  //    Purely client-side; the remote never sees it. +/−/⟲ buttons expose it
  //    for phones that don't pinch naturally.
  try {
    var screenElGet = function() { return document.getElementById('screen'); };

    // Apply the current zoom/pan as a CSS transform on #screen, clamping the
    // pan so the magnified canvas can't be dragged off the viewport.
    var applyZoom = function() {
      var s = screenElGet(); if (!s) return;
      var vw = window.innerWidth, vh = window.innerHeight;
      var minPx = vw * (1 - VIEWZOOM.z), minPy = vh * (1 - VIEWZOOM.z);
      VIEWZOOM.px = Math.min(0, Math.max(minPx, VIEWZOOM.px));
      VIEWZOOM.py = Math.min(0, Math.max(minPy, VIEWZOOM.py));
      s.style.transformOrigin = '0 0';
      s.style.transform = VIEWZOOM.z === 1 ? '' :
        'translate(' + VIEWZOOM.px + 'px,' + VIEWZOOM.py + 'px) scale(' + VIEWZOOM.z + ')';
    };
    // Zoom to newZ while keeping the content point under (cx,cy) stationary.
    var zoomAt = function(cx, cy, newZ) {
      newZ = Math.max(VIEWZOOM.min, Math.min(VIEWZOOM.max, newZ));
      var contentX = (cx - VIEWZOOM.px) / VIEWZOOM.z;
      var contentY = (cy - VIEWZOOM.py) / VIEWZOOM.z;
      VIEWZOOM.px = cx - contentX * newZ;
      VIEWZOOM.py = cy - contentY * newZ;
      VIEWZOOM.z = newZ;
      applyZoom();
    };
    var zoomReset = function() { VIEWZOOM.z = 1; VIEWZOOM.px = 0; VIEWZOOM.py = 0; applyZoom(); };
    var midpoint = function(t) {
      return { x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2 };
    };
    // Orientation flips invalidate the pan math — reset to 1x.
    window.addEventListener('orientationchange', zoomReset);

    // --- Unified touch handling: pinch-zoom, drag-pan/scroll, tap-click ---
    // Registered on window in CAPTURE phase so we run BEFORE xpra's own touch
    // handlers on #screen (which would otherwise translate every touch into a
    // mousedown+drag, breaking scroll and treating swipes as text-selection).
    //
    // We take over all touch events on the screen entirely:
    //   - 2 fingers → pinch magnifies the view (CSS transform, no remote zoom)
    //   - 2-finger tap (no pinch) → dismiss the native keyboard
    //   - 1 finger drag, zoomed in → pan the magnified view
    //   - 1 finger drag, at 1x → wheel events sent to remote (scroll the page)
    //   - 1 finger, no movement → click at the touch point AND raise the native
    //     keyboard (like the terminal — there's no on-screen keyboard button)
    //
    // xpra's wheel and mouse handlers on #screen forward synthetic events to
    // the remote just fine (its forwarders don't check event.isTrusted).
    // xpra attaches its wheel/mouse listeners to the <canvas> inside #screen,
    // not to the wrapper. Wheel/mouse events don't propagate down to children,
    // so we must dispatch directly on the canvas for xpra to forward them.
    var canvasGet = function() {
      var s = screenElGet();
      return s ? s.querySelector('canvas') : null;
    };
    var dist2 = function(t) {
      var dx = t[0].clientX - t[1].clientX, dy = t[0].clientY - t[1].clientY;
      return Math.sqrt(dx * dx + dy * dy);
    };
    var TAP_PX = 10;
    // SCROLL_TICK: pixels of finger travel per emitted wheel event. The remote
    // Chromium amplifies each wheel deltaY by ~3 lines (Chrome's default), so
    // dividing the raw finger delta keeps page scroll close to finger speed.
    // Higher value = slower scroll relative to finger.
    var SCROLL_TICK = 33;
    var touch = { mode: null, sx: 0, sy: 0, lx: 0, ly: 0, pinch: 0, pinch0: 0,
                  accum: 0, accumX: 0, twoFinger: false };

    var fireWheel = function(x, y, dx, dy) {
      var c = canvasGet(); if (!c) return;
      c.dispatchEvent(new WheelEvent('wheel', {
        clientX: x, clientY: y, deltaX: dx, deltaY: dy, deltaMode: 0,
        bubbles: true, cancelable: true
      }));
    };
    var fireTap = function(x, y) {
      var c = canvasGet(); if (!c) return;
      var opts = { clientX: x, clientY: y, button: 0, buttons: 1,
                   bubbles: true, cancelable: true };
      c.dispatchEvent(new MouseEvent('mousedown', opts));
      opts.buttons = 0;
      c.dispatchEvent(new MouseEvent('mouseup', opts));
      c.dispatchEvent(new MouseEvent('click', opts));
    };

    window.addEventListener('touchstart', function(e) {
      if (e.touches.length === 2) {
        touch.mode = 'pinch';
        touch.pinch = touch.pinch0 = dist2(e.touches);
        touch.twoFinger = true;       // a clean 2-finger tap dismisses the keyboard
        e.preventDefault(); e.stopPropagation();
      } else if (e.touches.length === 1) {
        var t = e.touches[0];
        touch.mode = null;            // undecided: tap vs scroll
        touch.sx = touch.lx = t.clientX;
        touch.sy = touch.ly = t.clientY;
        touch.accum = 0; touch.accumX = 0;
        touch.twoFinger = false;
        e.preventDefault(); e.stopPropagation();
      }
    }, { passive: false, capture: true });

    window.addEventListener('touchmove', function(e) {
      if (touch.mode === 'pinch' && e.touches.length === 2) {
        e.preventDefault(); e.stopPropagation();
        // Continuous magnification anchored at the pinch midpoint, like Safari.
        var d = dist2(e.touches);
        if (Math.abs(d - touch.pinch0) > 8) touch.twoFinger = false;  // real pinch, not a tap
        if (touch.pinch > 0) {
          var mid = midpoint(e.touches);
          zoomAt(mid.x, mid.y, VIEWZOOM.z * (d / touch.pinch));
        }
        touch.pinch = d;
      } else if (e.touches.length === 1) {
        var t = e.touches[0];
        e.preventDefault(); e.stopPropagation();
        if (touch.mode === null) {
          if (Math.abs(t.clientY - touch.sy) > TAP_PX ||
              Math.abs(t.clientX - touch.sx) > TAP_PX) {
            touch.mode = 'scroll';
          }
        }
        if (touch.mode === 'scroll') {
          touch.twoFinger = false;   // dragging is never a 2-finger tap
          var ddx = t.clientX - touch.lx, ddy = t.clientY - touch.ly;
          touch.lx = t.clientX; touch.ly = t.clientY;
          if (VIEWZOOM.z > 1.001) {
            // Magnified: pan the view, canvas following the finger (grab-pan).
            VIEWZOOM.px += ddx; VIEWZOOM.py += ddy;
            applyZoom();
          } else {
            // At 1x: scroll the remote page on both axes (finger UP → page
            // scrolls DOWN; finger LEFT → scrolls RIGHT). Accumulate raw pixels
            // and emit one SCROLL_TICK-sized wheel event per tick so speed
            // tracks the finger (xpra/Chromium amplify each wheel event).
            touch.accum  += -ddy;
            touch.accumX += -ddx;
            while (touch.accum >= SCROLL_TICK)  { fireWheel(t.clientX, t.clientY, 0,  SCROLL_TICK); touch.accum  -= SCROLL_TICK; }
            while (touch.accum <= -SCROLL_TICK) { fireWheel(t.clientX, t.clientY, 0, -SCROLL_TICK); touch.accum  += SCROLL_TICK; }
            while (touch.accumX >= SCROLL_TICK) { fireWheel(t.clientX, t.clientY,  SCROLL_TICK, 0); touch.accumX -= SCROLL_TICK; }
            while (touch.accumX <= -SCROLL_TICK){ fireWheel(t.clientX, t.clientY, -SCROLL_TICK, 0); touch.accumX += SCROLL_TICK; }
          }
        }
      }
    }, { passive: false, capture: true });

    window.addEventListener('touchend', function(e) {
      e.preventDefault(); e.stopPropagation();
      if (e.touches.length === 0) {
        if (touch.twoFinger) {
          // clean 2-finger tap → dismiss the native keyboard
          if (kbdBlur) kbdBlur();
        } else if (touch.mode === null) {
          // 1-finger tap → click, then raise the native keyboard (unless we just
          // dismissed it — don't let the dismissing tap immediately reopen it).
          fireTap(touch.sx, touch.sy);
          if (kbdFocus && Date.now() - kbdLastBlur > 500) kbdFocus();
        }
        touch.mode = null;
        touch.twoFinger = false;
      } else if (e.touches.length === 1 && touch.mode === 'pinch') {
        // One finger lifted during pinch — switch to scroll mode using the
        // remaining finger, no tap on its eventual release.
        var t = e.touches[0];
        touch.mode = 'scroll';
        touch.sx = touch.lx = t.clientX;
        touch.sy = touch.ly = t.clientY;
        touch.accum = 0; touch.accumX = 0;
      }
    }, { passive: false, capture: true });

    window.addEventListener('touchcancel', function() {
      touch.mode = null;
      touch.twoFinger = false;
    }, { passive: true, capture: true });
    // No on-screen zoom buttons — pinch to magnify, pinch back / orientation
    // flip to return to 1×.
  } catch(e) {
    console.warn('[xpra-patches] zoom patch failed:', e.message);
  }

  // 5. Paste on non-Mac. xpra uses Meta as its clipboard modifier on macOS but
  //    Control elsewhere, routed through the browser's `paste` event — which is
  //    unreliable on Windows (Cmd+V works on Mac, Ctrl+V often doesn't). On
  //    non-Mac we intercept Ctrl+V, read the local clipboard, and type it into
  //    the remote as key events. The working Mac Cmd+V path is left untouched.
  try {
    var isMacP = /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || '');
    if (!isMacP) {
      window.addEventListener('keydown', function(e) {
        if (!(e.ctrlKey && !e.shiftKey && !e.altKey && (e.key === 'v' || e.key === 'V'))) return;
        if (!navigator.clipboard || !navigator.clipboard.readText || !kbdSendChar) return;
        e.preventDefault(); e.stopPropagation();   // block xpra's own (failing) handling
        navigator.clipboard.readText().then(function(text) {
          if (!text) return;
          text = text.replace(/\r\n/g, '\n');
          for (var i = 0; i < text.length; i++) {
            var ch = text.charAt(i);
            if (ch === '\n' || ch === '\r') kbdSendKey('Enter', 'Enter', 13);
            else if (ch === '\t') kbdSendKey('Tab', 'Tab', 9);
            else kbdSendChar(ch);
          }
        }).catch(function() {});
      }, true);   // capture: run before xpra's document-level keydown
    }
  } catch(e) {
    console.warn('[xpra-patches] paste patch failed:', e.message);
  }
})();
