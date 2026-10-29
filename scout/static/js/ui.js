// Shared DOM and formatting helpers. Every page builds its DOM with el() and
// textContent so names, notes and report text can never inject markup.

const SVG_NS = "http://www.w3.org/2000/svg";
const SVG_TAGS = new Set([
  "svg", "g", "path", "line", "circle", "rect", "text", "polyline", "polygon", "title", "defs", "clipPath",
]);

/**
 * Create an element. attrs: class, text, dataset, style (object), on<Event> (function),
 * boolean attributes (true/false) and plain attributes. Children may be nodes,
 * strings (added as text) or arrays; null/undefined/false are skipped.
 */
export function el(tag, attrs = {}, ...children) {
  const node = SVG_TAGS.has(tag) ? document.createElementNS(SVG_NS, tag) : document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false || key === "value") continue;
    if (key === "class") node.setAttribute("class", value);
    else if (key === "text") node.textContent = String(value);
    else if (key === "dataset") Object.assign(node.dataset, value);
    else if (key === "style" && typeof value === "object") setStyles(node, value);
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (value === true) node.setAttribute(key, "");
    else if (key in node && !SVG_TAGS.has(tag) && typeof value !== "string") node[key] = value;
    else node.setAttribute(key, String(value));
  }
  append(node, children);
  // Set value last so a <select> already has its options and a <textarea> gets its text.
  if (attrs && attrs.value !== undefined && attrs.value !== null) node.value = attrs.value;
  return node;
}

function setStyles(node, styles) {
  for (const [prop, value] of Object.entries(styles)) {
    if (prop.startsWith("--")) node.style.setProperty(prop, value);
    else node.style[prop] = value;
  }
}

function append(node, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    if (Array.isArray(child)) append(node, child);
    else node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

/** getElementById that fails loudly (a missing id is a bug in the page, not a user error). */
export function byId(id) {
  const node = document.getElementById(id);
  if (!node) throw new Error(`Page is missing element #${id}`);
  return node;
}

/** Replace all children of a node. */
export function setChildren(node, ...children) {
  node.replaceChildren();
  append(node, children);
  return node;
}

export function show(node, visible = true) {
  node.hidden = !visible;
}

// ---------------------------------------------------------------------------
// Errors and notices
// ---------------------------------------------------------------------------

/** Turn anything thrown into {title, message, hint, retryable}. */
function describeError(err) {
  if (err && err.info) return err.info;
  if (err && err.name === "AbortError") {
    return { title: "Cancelled", message: "The request was cancelled.", hint: null, retryable: true };
  }
  return {
    title: "Something went wrong",
    message: (err && err.message) || "An unexpected error occurred in the page.",
    hint: "Reload the page and try again.",
    retryable: true,
  };
}

/** Friendly error box: title, message, hint and optional action buttons. Never raw JSON. */
export function errorBox(err, actions = []) {
  const info = describeError(err);
  return el(
    "div",
    { class: "notice notice-error", role: "alert" },
    el("strong", { class: "notice-title", text: info.title || "Error" }),
    info.message ? el("p", { text: info.message }) : null,
    info.hint ? el("p", { class: "notice-hint", text: info.hint }) : null,
    actions.length ? el("div", { class: "notice-actions" }, actions) : null,
  );
}

/** Show an error inside a container (an aria-live region), replacing what was there. */
export function showError(container, err, actions = []) {
  setChildren(container, errorBox(err, actions));
  container.hidden = false;
}

export function clearError(container) {
  container.replaceChildren();
}

/** Coloured notice: kind = info | success | warning | error. */
export function notice(kind, title, message, hint) {
  return el(
    "div",
    { class: `notice notice-${kind}`, role: kind === "error" ? "alert" : "status" },
    title ? el("strong", { class: "notice-title", text: title }) : null,
    message ? el("p", { text: message }) : null,
    hint ? el("p", { class: "notice-hint", text: hint }) : null,
  );
}

let toastTimer = null;

/** Short-lived message at the bottom of the screen (announced to screen readers). */
export function toast(message, kind = "info") {
  let region = document.getElementById("toast");
  if (!region) {
    region = el("div", { id: "toast", class: "toast", role: "status", "aria-live": "polite" });
    document.body.append(region);
  }
  region.className = `toast toast-${kind} toast-visible`;
  region.textContent = message;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => region.classList.remove("toast-visible"), 4000);
}

/** Disable a button while an async action runs; restores the label afterwards. */
export async function withBusy(button, busyLabel, action) {
  const label = button.textContent;
  button.disabled = true;
  button.setAttribute("aria-busy", "true");
  if (busyLabel) button.textContent = busyLabel;
  try {
    return await action();
  } finally {
    button.disabled = false;
    button.removeAttribute("aria-busy");
    button.textContent = label;
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/** Seconds -> "m:ss" (or "h:mm:ss" past an hour). */
export function formatClock(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

/** 0..1 fraction -> "45.6%" ("–" when unknown). */
export function formatPct(fraction, digits = 1) {
  if (fraction === null || fraction === undefined || Number.isNaN(fraction)) return "–";
  return `${(fraction * 100).toFixed(digits)}%`;
}

export function formatNumber(value, digits = 0) {
  if (value === null || value === undefined || Number.isNaN(value)) return "–";
  return Number(value).toFixed(digits);
}

export function formatBytes(bytes) {
  if (!bytes && bytes !== 0) return "–";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

/** Seconds -> "3 min 20 s" style duration for ETAs. */
export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "–";
  const s = Math.round(seconds);
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ${s % 60} s`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

/** "2026-01-17" (a date without time zone) -> "Jan 17, 2026". */
export function formatDate(isoDate) {
  if (!isoDate) return "";
  const [y, m, d] = String(isoDate).slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return String(isoDate);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

export function formatDateTime(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? String(iso) : date.toLocaleString();
}

/** Seconds ago -> "12 s ago" / "5 min ago". */
export function formatAgo(seconds) {
  if (seconds === null || seconds === undefined) return "never";
  if (seconds < 90) return `${Math.round(seconds)} s ago`;
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`;
  return `${Math.round(seconds / 3600)} h ago`;
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

export function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(new DOMException("Aborted", "AbortError"));
    }, { once: true });
  });
}

export function debounce(fn, ms = 200) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

/** Read a localStorage value without ever throwing (private windows, blocked storage). */
export function storageGet(key, fallback = null) {
  try {
    const raw = window.localStorage.getItem(key);
    return raw === null ? fallback : JSON.parse(raw);
  } catch {
    return fallback;
  }
}

export function storageSet(key, value) {
  try {
    if (value === null || value === undefined) window.localStorage.removeItem(key);
    else window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage is a convenience only; ignore failures.
  }
}

/** Game id from the page URL: /games/<id> or /games/<id>/roster. */
export function gameIdFromPath() {
  const match = window.location.pathname.match(/\/games\/([^/]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

/** True when keyboard focus is somewhere typing or a native control should own the key. */
export function isTypingTarget(target) {
  if (!target || !(target instanceof Element)) return false;
  if (target.isContentEditable) return true;
  return Boolean(target.closest("input, textarea, select, button, a[href], summary, [role=tab], [role=slider], dialog"));
}

/**
 * Centre a tooltip (CSS: translateX(-50%)) on x, in px from its container's left edge,
 * but keep it inside the container so it can't widen the page on a phone.
 */
export function placeTip(tip, x, containerWidth) {
  const half = Math.min(tip.offsetWidth, containerWidth) / 2;
  tip.style.left = `${Math.round(Math.max(half, Math.min(containerWidth - half, x)))}px`;
}

/** Size a canvas to its CSS box at device resolution; returns a cleared context in CSS pixels. */
export function prepareCanvas(canvas) {
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  return { ctx, width, height };
}

/** Wire an ARIA tablist: buttons [role=tab] with aria-controls pointing at panels. */
export function setupTabs(tablist, onChange) {
  const tabs = [...tablist.querySelectorAll("[role=tab]")];
  const select = (tab, focus = false) => {
    for (const t of tabs) {
      const active = t === tab;
      t.setAttribute("aria-selected", String(active));
      t.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(t.getAttribute("aria-controls"));
      if (panel) panel.hidden = !active;
    }
    if (focus) tab.focus();
    onChange?.(tab);
  };
  tablist.addEventListener("click", (e) => {
    const tab = e.target.closest("[role=tab]");
    if (tab) select(tab);
  });
  tablist.addEventListener("keydown", (e) => {
    const i = tabs.indexOf(document.activeElement);
    if (i < 0) return;
    const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
    if (next === undefined) return;
    e.preventDefault();
    select(tabs[(next + tabs.length) % tabs.length], true);
  });
  const initial = tabs.find((t) => t.getAttribute("aria-selected") === "true") || tabs[0];
  if (initial) select(initial);
  return { select };
}
