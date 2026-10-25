// Quill — front-end shell. Markdown parsing/saving lives in Zig; this file is
// only layout, editing conveniences, and the split-pane wiring.
(() => {
  "use strict";

  const INIT = Object.assign(
    { name: "untitled.md", path: null, text: "", read_only: false },
    window.__QUILL__ || {},
  );

  const $ = (id) => document.getElementById(id);

  // setHtml() gives the page an opaque origin, where localStorage throws.
  // Persistence is a nicety, so degrade quietly to in-memory values.
  const memory = new Map();
  const store = {
    get(key, fallback) {
      try {
        const v = localStorage.getItem(key);
        if (v !== null) return v;
      } catch {}
      return memory.has(key) ? memory.get(key) : fallback;
    },
    set(key, value) {
      memory.set(key, value);
      try { localStorage.setItem(key, value); } catch {}
    },
  };

  const els = {
    src: $("src"),
    preview: $("preview"),
    docname: $("docname"),
    dirty: $("dirty"),
    pos: $("st-pos"),
    words: $("st-words"),
    chars: $("st-chars"),
    msg: $("st-msg"),
    panes: $("panes"),
    splitter: $("splitter"),
    file: $("file"),
    toast: $("toast"),
    btnOpen: $("btn-open"),
    btnSave: $("btn-save"),
    btnSaveAs: $("btn-saveas"),
    btnSplit: $("btn-split"),
    btnTheme: $("btn-theme"),
  };

  const bridge = {
    ok: typeof window.qRender === "function",
    render: (md) => window.qRender(md),
    save: (text) => window.qSave(text),
    title: (t) => (window.qTitle ? window.qTitle(t) : undefined),
    openUrl: (u) => (window.qOpenUrl ? window.qOpenUrl(u) : undefined),
  };

  const state = {
    name: INIT.name || "untitled.md",
    path: INIT.path || null,
    dirty: false,
    savedText: null,
    token: 0,
    lastRendered: null,
    theme: store.get("quill.theme", "auto"),
    zoom: clampZoom(parseFloat(store.get("quill.zoom", "1"))),
    soloPreview: false,
  };

  // ── small utilities ────────────────────────────────────────────────────────

  function clampZoom(z) {
    if (!Number.isFinite(z)) return 1;
    return Math.min(1.8, Math.max(0.8, z));
  }

  let toastTimer = 0;
  function toast(message) {
    els.toast.textContent = message;
    els.toast.hidden = false;
    requestAnimationFrame(() => els.toast.classList.add("show"));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      els.toast.classList.remove("show");
      setTimeout(() => { els.toast.hidden = true; }, 220);
    }, 2200);
  }

  let msgTimer = 0;
  function status(message) {
    els.msg.textContent = message;
    els.msg.classList.add("show");
    clearTimeout(msgTimer);
    msgTimer = setTimeout(() => els.msg.classList.remove("show"), 1600);
  }

  // ── render pipeline ────────────────────────────────────────────────────────

  async function renderNow(force) {
    const text = els.src.value;
    if (!bridge.ok) {
      els.preview.innerHTML = '<p class="empty">Zig bridge unavailable.</p>';
      return;
    }
    if (!force && text === state.lastRendered) return;

    const token = ++state.token;
    const started = performance.now();
    try {
      const html = await bridge.render(text);
      if (token !== state.token) return; // a newer keystroke already won
      const ms = performance.now() - started;
      els.preview.innerHTML = html && html.trim()
        ? html
        : '<p class="empty">Nothing to preview yet — start typing on the left.</p>';
      state.lastRendered = text;
      attachHandlers();
      if (text.length > 0) status(`rendered in ${ms < 1 ? "<1" : ms.toFixed(0)} ms`);
    } catch (err) {
      els.preview.innerHTML = '<p class="empty">Render failed.</p>';
      status(String(err));
    }
  }

  let renderTimer = 0;
  function scheduleRender() {
    clearTimeout(renderTimer);
    renderTimer = setTimeout(() => renderNow(false), 80);
  }

  function attachHandlers() {
    for (const a of els.preview.querySelectorAll("a[href]")) {
      a.addEventListener("click", (ev) => {
        const href = a.getAttribute("href") || "";
        if (href.startsWith("#")) return; // in-document anchor: let the browser scroll
        ev.preventDefault();
        if (/^(https?|mailto):/i.test(href)) {
          bridge.openUrl(a.href);
        } else {
          toast("Only http(s) and mailto links open externally");
        }
      });
    }
  }

  // ── document state ─────────────────────────────────────────────────────────

  function setTitle() {
    const prefix = state.dirty ? "• " : "";
    bridge.title(`${prefix}${state.name} — Quill`);
  }

  function setDirty(value) {
    state.dirty = value;
    els.dirty.hidden = !value;
    setTitle();
  }

  function loadDoc(text, name, path) {
    els.src.value = text;
    els.src.setSelectionRange(0, 0);
    els.src.scrollTop = 0;
    els.preview.parentElement.scrollTop = 0;

    state.name = name || "untitled.md";
    state.path = path || null;
    // A textarea normalizes CRLF to LF, so track the *normalized* text.
    state.savedText = els.src.value;

    els.docname.textContent = state.name;
    els.docname.title = path || `${state.name} (not saved to disk yet)`;

    setDirty(false);
    state.lastRendered = null;
    updateStats();
    renderNow(true);
    els.src.focus({ preventScroll: true });
  }

  function updateStats() {
    const text = els.src.value;
    const chars = [...text].length;
    let words = 0;
    if (text.trim()) {
      const m = text.match(/[\p{L}\p{N}][\p{L}\p{N}'’_-]*/gu);
      words = m ? m.length : 0;
    }
    els.chars.textContent = `${chars.toLocaleString()} chars`;
    els.words.textContent = `${words.toLocaleString()} words`;

    const upto = text.slice(0, els.src.selectionStart);
    const lines = (upto.match(/\n/g) || []).length + 1;
    const col = upto.length - upto.lastIndexOf("\n");
    els.pos.textContent = `${lines}:${col}`;
  }

  // ── file actions ───────────────────────────────────────────────────────────

  async function save() {
    if (!state.path) {
      saveAs();
      return;
    }
    try {
      await bridge.save(els.src.value);
      state.savedText = els.src.value;
      setDirty(false);
      status(`saved ${state.name}`);
    } catch (err) {
      toast(`Could not save: ${err}`);
    }
  }

  function saveAs() {
    const suggested = state.name && state.name !== "untitled.md" ? state.name : "untitled.md";
    const blob = new Blob([els.src.value], { type: "text/markdown;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = suggested;
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    setTimeout(() => {
      URL.revokeObjectURL(url);
      a.remove();
    }, 1500);
    state.savedText = els.src.value;
    setDirty(false);
    toast(`Exported a copy as ${suggested}`);
  }

  function pickFile() {
    els.file.value = "";
    els.file.click();
  }

  els.file.addEventListener("change", async () => {
    const file = els.file.files && els.file.files[0];
    if (!file) return;
    if (file.size > 32 * 1024 * 1024) {
      toast("That file is larger than 32 MB");
      return;
    }
    try {
      const text = await file.text();
      loadDoc(text, file.name, null);
      toast(`Opened ${file.name} — Save exports a copy, since the browser picker hides the real path`);
    } catch (err) {
      toast(`Could not read that file: ${err}`);
    }
  });

  // ── editing helpers ────────────────────────────────────────────────────────

  function wrapSelection(before, after, placeholder) {
    const el = els.src;
    const start = el.selectionStart;
    const end = el.selectionEnd;
    const selected = el.value.slice(start, end) || placeholder;
    el.setRangeText(before + selected + after, start, end, "end");
    el.setSelectionRange(start + before.length, start + before.length + selected.length);
    onInput();
  }

  function onInput() {
    setDirty(els.src.value !== state.savedText);
    updateStats();
    scheduleRender();
  }

  els.src.addEventListener("input", onInput);
  els.src.addEventListener("keyup", updateStats);
  els.src.addEventListener("click", updateStats);

  els.src.addEventListener("keydown", (ev) => {
    if (ev.key === "Tab" && !ev.ctrlKey && !ev.metaKey) {
      ev.preventDefault();
      const el = els.src;
      el.setRangeText("  ", el.selectionStart, el.selectionEnd, "end");
      onInput();
    }
  });

  document.addEventListener("keydown", (ev) => {
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const key = ev.key.toLowerCase();

    if (key === "s") {
      ev.preventDefault();
      ev.shiftKey ? saveAs() : save();
    } else if (key === "o") {
      ev.preventDefault();
      pickFile();
    } else if (key === "e") {
      ev.preventDefault();
      togglePreview();
    } else if (key === "b") {
      ev.preventDefault();
      wrapSelection("**", "**", "bold text");
    } else if (key === "i") {
      ev.preventDefault();
      wrapSelection("*", "*", "emphasis");
    } else if (key === "k") {
      ev.preventDefault();
      wrapSelection("[", "](https://)", "link text");
    } else if (key === "=" || key === "+") {
      ev.preventDefault();
      setZoom(state.zoom + 0.1);
    } else if (key === "-") {
      ev.preventDefault();
      setZoom(state.zoom - 0.1);
    } else if (key === "0") {
      ev.preventDefault();
      setZoom(1);
    }
  });

  function setZoom(z) {
    state.zoom = clampZoom(Math.round(z * 100) / 100);
    document.documentElement.style.setProperty("--zoom", String(state.zoom));
    store.set("quill.zoom", String(state.zoom));
    status(`zoom ${Math.round(state.zoom * 100)}%`);
  }

  // ── theme ──────────────────────────────────────────────────────────────────

  const THEMES = ["auto", "light", "dark"];
  const THEME_LABEL = { auto: "auto (follow system)", light: "light", dark: "dark" };

  function applyTheme() {
    document.documentElement.dataset.theme = state.theme;
    els.btnTheme.title = `Theme: ${THEME_LABEL[state.theme]}`;
    store.set("quill.theme", state.theme);
  }

  els.btnTheme.addEventListener("click", () => {
    state.theme = THEMES[(THEMES.indexOf(state.theme) + 1) % THEMES.length];
    applyTheme();
    toast(`Theme: ${THEME_LABEL[state.theme]}`);
  });

  // ── split pane ─────────────────────────────────────────────────────────────

  function togglePreview() {
    state.soloPreview = !state.soloPreview;
    els.panes.classList.toggle("solo", state.soloPreview);
    els.btnSplit.classList.toggle("active", state.soloPreview);
  }

  els.btnSplit.addEventListener("click", togglePreview);

  let dragging = false;
  function onSplitMove(ev) {
    if (!dragging) return;
    const rect = els.panes.getBoundingClientRect();
    const pct = ((ev.clientX - rect.left) / rect.width) * 100;
    const clamped = Math.min(80, Math.max(20, pct));
    els.panes.style.setProperty("--split", `${clamped}%`);
  }

  els.splitter.addEventListener("pointerdown", (ev) => {
    dragging = true;
    els.splitter.classList.add("dragging");
    els.splitter.setPointerCapture(ev.pointerId);
    document.body.style.cursor = "col-resize";
  });
  els.splitter.addEventListener("pointermove", onSplitMove);
  els.splitter.addEventListener("pointerup", (ev) => {
    dragging = false;
    els.splitter.classList.remove("dragging");
    els.splitter.releasePointerCapture(ev.pointerId);
    document.body.style.cursor = "";
  });

  // ── buttons ────────────────────────────────────────────────────────────────

  els.btnOpen.addEventListener("click", pickFile);
  els.btnSave.addEventListener("click", save);
  els.btnSaveAs.addEventListener("click", saveAs);

  // ── boot ───────────────────────────────────────────────────────────────────

  document.documentElement.style.setProperty("--zoom", String(state.zoom));
  applyTheme();
  loadDoc(INIT.text || "", INIT.name, INIT.path);
  setTitle();
})();
