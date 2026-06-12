(function() {
  // Permanent action buttons: always visible, greyed out when no file selected.
  // When clicked, they delegate to Vue's actual button if it exists.
  var PERMANENT_BUTTONS = [
    { icon: "public", label: "Browser", custom: true },
    { icon: "share", label: "Share" },
    { icon: "mode_edit", label: "Rename" },
    { icon: "content_copy", label: "Copy" },
    { icon: "forward", label: "Move" },
    { icon: "delete", label: "Delete" },
    { icon: "file_download", label: "Download" }
  ];

  var style = document.createElement("style");
  style.textContent = [
    "header .action.fb-permanent { display: inline-flex !important; flex-direction: column !important; align-items: center !important; border-radius: 4px !important; padding: 2px 6px !important; min-width: 0 !important; width: auto !important; }",
    "header .action.fb-permanent span:not(.counter) { display: block !important; font-size: 11px !important; line-height: 1.2 !important; text-align: center !important; padding: 0 !important; max-width: 60px !important; word-wrap: break-word !important; overflow-wrap: break-word !important; white-space: normal !important; }",
    "header .action.fb-permanent i { font-size: 20px !important; margin: 0 !important; padding: 2px !important; display: block !important; }",
    "header .action.fb-permanent .counter { position: absolute !important; top: -4px !important; right: -4px !important; bottom: auto !important; left: auto !important; }",
    "header #dropdown .action { display: inline-flex !important; flex-direction: column !important; align-items: center !important; border-radius: 4px !important; padding: 2px 6px !important; min-width: 0 !important; width: auto !important; }",
    "header #dropdown .action span:not(.counter) { display: block !important; font-size: 11px !important; line-height: 1.2 !important; text-align: center !important; padding: 0 !important; max-width: 60px !important; word-wrap: break-word !important; overflow-wrap: break-word !important; white-space: normal !important; }",
    "header #dropdown .action i { font-size: 20px !important; margin: 0 !important; padding: 2px !important; display: block !important; }",
    "header .fb-permanent.disabled { opacity: 0.25 !important; pointer-events: none !important; }",
    // Mobile: let the action toolbar wrap to multiple rows instead of clipping
    // buttons off the right edge OR collapsing them into a "..." overflow menu.
    // FileBrowser's stock behavior on narrow viewports is to hide extras inside
    // a popup #dropdown opened by a "more" button; we instead force #dropdown
    // to render inline + wrapped and hide the more-button so every action is
    // visible without an extra tap.
    "@media (max-width: 736px) {",
    "  header { flex-wrap: wrap !important; height: auto !important; min-height: 4em !important; row-gap: 4px !important; padding-top: 4px !important; padding-bottom: 4px !important; }",
    "  header #dropdown { display: flex !important; flex-wrap: wrap !important; position: static !important; visibility: visible !important; opacity: 1 !important; transform: none !important; box-shadow: none !important; background: transparent !important; height: auto !important; max-height: none !important; row-gap: 4px !important; padding: 0 !important; }",
    "  header .action, header .action.fb-permanent { flex: 0 0 auto !important; }",
    // Hide FileBrowser's "..." / more-actions trigger so the dropdown buttons
    // stay flattened into the header instead of being a popup.
    "  header > .action[aria-haspopup], header .action.show-more, header > .action.more, header > .action[title=\"More\"], header > .action[aria-label=\"More\"] { display: none !important; }",
    "  main { margin-top: 0 !important; padding-top: 0 !important; }",
    "}",
    // Hide FileBrowser's selection-action popups: #file-selection is the
    // bottom-floating "X selected · [icons]" bar that appears on mobile when a
    // file is tapped; .context-menu is the right-click / long-press menu.
    // Every action already lives in the top toolbar, so both are redundant.
    "#file-selection, .context-menu { display: none !important; }",
  ].join("\n");
  document.head.appendChild(style);

  // Office files (Word/Excel/PPT/ODF) get two extra toolbar buttons, shown only
  // when such a file is open: View (server renders a read-only PDF in the shell)
  // and Edit (opens it in LibreOffice on the Browser desktop). Both delegate to
  // the parent shell, which holds the Cloudflare Access cookie for /api calls.
  var OFFICE_RE = /\.(docx?|xlsx?|pptx?|odt|ods|odp|rtf|csv)$/i;
  var OFFICE_BUTTONS = [
    { icon: "visibility", label: "View", act: "office-view" },
    { icon: "border_color", label: "Edit", act: "office-edit" }
  ];

  var RENAMES = {
    "Select multiple": "Select", "Switch view": "View", "Toggle sidebar": "Menu",
    "Select Multiple": "Select", "Switch View": "View", "Toggle Sidebar": "Menu"
  };

  function shortenLabels() {
    document.querySelectorAll("header #dropdown .action span:not(.counter)").forEach(function(span) {
      var text = span.textContent.trim();
      if (RENAMES[text]) span.textContent = RENAMES[text];
    });
  }

  // Check if any item (file or folder) is selected
  function hasSelection() {
    return !!document.querySelector('[aria-selected="true"]');
  }

  // Get file path for Browser button — only files, not folders
  function getFilePath() {
    var p = location.pathname.replace(/.*\/files\/?/, "");
    if (p && !p.endsWith("/") && !/^(static|api|login|settings)\b/.test(p)) return p;
    var sel = document.querySelector('[aria-selected="true"]:not([data-dir="true"])');
    if (sel) {
      var name = sel.getAttribute("aria-label");
      if (name) return (p || "") + name;
    }
    return null;
  }

  function openInBrowser(filePath) {
    var url = "http://127.0.0.1/fileview/" + filePath;
    fetch("/api/browser/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: url })
    });
    try { window.top.postMessage({ type: "switch-to-browser" }, "*"); } catch(e) {}
  }

  // Find Vue's actual button by icon name and click it
  function clickVueButton(iconName) {
    var buttons = document.querySelectorAll("header .action:not(.fb-permanent)");
    for (var i = 0; i < buttons.length; i++) {
      var icon = buttons[i].querySelector("i.material-icons");
      if (icon && icon.textContent.trim() === iconName) {
        buttons[i].style.pointerEvents = "";
        buttons[i].click();
        return;
      }
    }
  }

  function injectPermanentButtons() {
    var header = document.querySelector("header");
    if (!header || header.querySelector(".fb-permanent")) return;
    var dropdown = header.querySelector("#dropdown");
    if (!dropdown) return;

    PERMANENT_BUTTONS.forEach(function(def) {
      var btn = document.createElement("button");
      btn.className = "action fb-permanent disabled";
      btn.title = def.label;
      btn.setAttribute("aria-label", def.label);
      btn.setAttribute("data-icon", def.icon);
      btn.innerHTML = '<i class="material-icons">' + def.icon + '</i><span>' + def.label + '</span>';
      btn.addEventListener("click", function() {
        if (btn.classList.contains("disabled")) return;
        if (def.custom) {
          var fp = getFilePath();
          if (fp) openInBrowser(fp);
        } else {
          clickVueButton(def.icon);
        }
      });
      header.insertBefore(btn, dropdown);
    });
  }

  function injectOfficeButtons() {
    var header = document.querySelector("header");
    if (!header || header.querySelector(".fb-office")) return;
    var dropdown = header.querySelector("#dropdown");
    if (!dropdown) return;
    OFFICE_BUTTONS.forEach(function(def) {
      var btn = document.createElement("button");
      btn.className = "action fb-permanent fb-office";
      btn.title = def.label;
      btn.setAttribute("aria-label", def.label);
      btn.setAttribute("data-icon", def.icon);
      btn.style.display = "none";   // shown only for office files
      btn.innerHTML = '<i class="material-icons">' + def.icon + '</i><span>' + def.label + '</span>';
      btn.addEventListener("click", function() {
        var fp = getFilePath();
        if (fp && OFFICE_RE.test(fp)) {
          try { window.top.postMessage({ type: def.act, path: fp }, "*"); } catch (e) {}
        }
      });
      header.insertBefore(btn, dropdown);
    });
  }

  function updateOfficeButtons() {
    var fp = getFilePath();
    var show = !!(fp && OFFICE_RE.test(fp));
    document.querySelectorAll("header .fb-office").forEach(function(btn) {
      btn.style.display = show ? "" : "none";
      btn.classList.remove("disabled");
    });
  }

  function updatePermanentButtons() {
    var selected = hasSelection();
    var filePath = getFilePath();
    document.querySelectorAll("header .fb-permanent:not(.fb-office)").forEach(function(btn) {
      var icon = btn.getAttribute("data-icon");
      // Browser button only active for files, not folders
      var active = icon === "public" ? !!filePath : selected;
      if (active) btn.classList.remove("disabled");
      else btn.classList.add("disabled");
    });
  }

  // Hide Vue's dynamic buttons — find any .action in header that isn't ours
  var DYNAMIC_ICON_SET = {};
  PERMANENT_BUTTONS.forEach(function(b) { DYNAMIC_ICON_SET[b.icon] = true; });

  function hideVueButtons() {
    document.querySelectorAll("header .action:not(.fb-permanent)").forEach(function(btn) {
      var icon = btn.querySelector("i.material-icons");
      if (icon && DYNAMIC_ICON_SET[icon.textContent.trim()]) {
        btn.style.cssText = "position:absolute!important;width:0!important;height:0!important;overflow:hidden!important;opacity:0!important;";
      }
    });
  }

  var patching = false;
  function patchAll() {
    if (patching) return;
    patching = true;
    shortenLabels();
    injectPermanentButtons();
    injectOfficeButtons();
    updatePermanentButtons();
    updateOfficeButtons();
    hideVueButtons();
    patching = false;
  }

  // Vue emits bursts of mutations; coalesce them into one sweep per animation
  // frame instead of running patchAll on every single mutation. The observer
  // covers DOM structure + selection changes, so the old always-on 2s polling
  // fallback is unnecessary.
  var scheduled = false;
  function schedulePatch() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(function() { scheduled = false; patchAll(); });
  }
  var observer = new MutationObserver(schedulePatch);
  observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["aria-selected"] });
  schedulePatch();
})();
