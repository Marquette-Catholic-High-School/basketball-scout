"""Regression tests from the frontend review.

The real page scripts in ``scout/static/js`` run in node against a small fake DOM that
is built from the real HTML page. ``fetch`` and ``XMLHttpRequest`` are answered by
routes each test registers, and timers are shortened so job polling runs at once.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from html.parser import HTMLParser
from pathlib import Path

import pytest

from scout.schemas import EventType, GameStatus, JobKind, JobStage, PlayOutcome, PlayType, ShotZone

REPO = Path(__file__).resolve().parent.parent
STATIC = REPO / "scout" / "static"
NODE = shutil.which("node")

VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class _TreeBuilder(HTMLParser):
    """HTML -> nested ``[tag, attrs, children]`` lists (text nodes are plain strings)."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root: list = ["#root", {}, []]
        self.stack: list[list] = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        node = [tag, {k: v if v is not None else "" for k, v in attrs}, []]
        self.stack[-1][2].append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.stack[-1][2].append([tag, {k: v if v is not None else "" for k, v in attrs}, []])

    def handle_endtag(self, tag: str) -> None:
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                return

    def handle_data(self, data: str) -> None:
        self.stack[-1][2].append(data)


def page_body(name: str) -> list:
    builder = _TreeBuilder()
    builder.feed((STATIC / name).read_text(encoding="utf-8"))
    todo = [builder.root]
    while todo:
        node = todo.pop()
        if node[0] == "body":
            return node
        todo.extend(child for child in node[2] if isinstance(child, list))
    raise AssertionError(f"{name} has no <body>")


FAKE_DOM_JS = r"""
// A small fake browser: enough DOM, events, fetch and XHR for the page scripts.
const realSetTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;

export const pause = (ms = 1) => new Promise((resolve) => realSetTimeout(resolve, ms));

/** Let pending promises, fake requests and (shortened) timers run. */
export async function settle(rounds = 60) {
  for (let i = 0; i < rounds; i += 1) await pause(1);
}

export class FakeEvent {
  constructor(type, init = {}) {
    Object.assign(this, init);
    this.type = type;
    this.bubbles = init.bubbles !== false;
    this.defaultPrevented = false;
    this.target = null;
    this.currentTarget = null;
    this.stopped = false;
  }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() { this.stopped = true; }
}

class Target {
  constructor() { this.listeners = {}; }
  addEventListener(type, fn, options) {
    (this.listeners[type] ||= []).push({ fn, once: Boolean(options && options.once) });
  }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((l) => l.fn !== fn);
  }
  fireHere(event) {
    event.currentTarget = this;
    for (const l of [...(this.listeners[event.type] || [])]) {
      if (l.once) this.removeEventListener(event.type, l.fn);
      l.fn.call(this, event);
    }
  }
  dispatchEvent(event) {
    event.target = this;
    const path = [];
    for (let node = this; node; node = node.parentNode) path.push(node);
    if (path[path.length - 1] === globalThis.document) path.push(globalThis.window);
    for (const node of event.bubbles ? path : [this]) {
      node.fireHere(event);
      if (event.stopped) break;
    }
    return !event.defaultPrevented;
  }
}

class Node extends Target {
  constructor(doc) {
    super();
    this.ownerDocument = doc;
    this.parentNode = null;
    this.childNodes = [];
  }
  get parentElement() { return this.parentNode instanceof Element ? this.parentNode : null; }
  get children() { return this.childNodes.filter((n) => n instanceof Element); }
  get firstChild() { return this.childNodes[0] || null; }
  get lastElementChild() { const c = this.children; return c[c.length - 1] || null; }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(""); }
  set textContent(value) {
    this.replaceChildren();
    if (value !== null && value !== undefined && value !== "") this.append(String(value));
  }
  append(...nodes) {
    for (const node of nodes) this.adopt(typeof node === "string" ? new Text(this.ownerDocument, node) : node);
  }
  appendChild(node) { this.adopt(node); return node; }
  adopt(node) {
    if (node instanceof DocumentFragment) {
      for (const child of [...node.childNodes]) this.adopt(child);
      return;
    }
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.push(node);
    this.changed();
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    node.parentNode = null;
    const doc = this.ownerDocument;
    if (doc && node.contains(doc.activeElement)) doc.activeElement = doc.body; // focus goes with the node
    this.changed();
    return node;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  replaceChildren(...nodes) {
    for (const child of [...this.childNodes]) this.removeChild(child);
    this.append(...nodes);
  }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  changed() {}
}

class Text extends Node {
  constructor(doc, data) { super(doc); this.data = String(data); }
  get textContent() { return this.data; }
  set textContent(value) { this.data = String(value); }
  cloneNode() { return new Text(this.ownerDocument, this.data); }
}

class DocumentFragment extends Node {}

class Style {
  setProperty(name, value) { this[name] = String(value); }
  getPropertyValue(name) { return this[name] === undefined ? "" : String(this[name]); }
  removeProperty(name) { delete this[name]; }
}

class ClassList {
  constructor(el) { this.el = el; }
  list() { return (this.el.getAttribute("class") || "").split(/\s+/).filter(Boolean); }
  contains(name) { return this.list().includes(name); }
  add(...names) {
    const list = this.list();
    for (const name of names) if (!list.includes(name)) list.push(name);
    this.el.setAttribute("class", list.join(" "));
  }
  remove(...names) { this.el.setAttribute("class", this.list().filter((n) => !names.includes(n)).join(" ")); }
  toggle(name, force) {
    const want = force === undefined ? !this.contains(name) : Boolean(force);
    if (want) this.add(name);
    else this.remove(name);
    return want;
  }
}

function datasetFor(el) {
  const attr = (key) => `data-${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;
  return new Proxy({}, {
    get: (_, key) => (typeof key === "string" && el.hasAttribute(attr(key)) ? el.getAttribute(attr(key)) : undefined),
    set: (_, key, value) => { el.setAttribute(attr(key), value); return true; },
    has: (_, key) => typeof key === "string" && el.hasAttribute(attr(key)),
  });
}

function compoundMatches(el, selector) {
  const tokens = selector.match(/\[[^\]]*\]|:[\w-]+|[#.]?[\w-]+|\*/g) || [];
  return tokens.every((token) => {
    if (token === "*") return true;
    if (token[0] === "#") return el.getAttribute("id") === token.slice(1);
    if (token[0] === ".") return el.classList.contains(token.slice(1));
    if (token === ":checked") return Boolean(el.checked);
    if (token[0] === ":") throw new Error(`fake DOM: unsupported selector ${token}`);
    if (token[0] === "[") {
      const m = token.slice(1, -1).match(/^([\w-]+)(?:=(["']?)(.*)\2)?$/);
      if (!m) throw new Error(`fake DOM: bad selector ${token}`);
      return el.hasAttribute(m[1]) && (m[3] === undefined || el.getAttribute(m[1]) === m[3]);
    }
    return el.localName === token.toLowerCase();
  });
}

/** Selector lists of compound selectors, with descendant combinators (spaces). */
function matches(el, selector) {
  return selector.split(",").some((complex) => {
    const parts = complex.trim().split(/\s+/);
    if (!compoundMatches(el, parts.pop())) return false;
    let node = el.parentElement;
    while (parts.length) {
      while (node && !compoundMatches(node, parts[parts.length - 1])) node = node.parentElement;
      if (!node) return false;
      parts.pop();
      node = node.parentElement;
    }
    return true;
  });
}

class Context2D {
  constructor() { Object.assign(this, { fillStyle: "#000000", strokeStyle: "#000000", font: "", lineWidth: 1 }); }
  measureText(text) { return { width: String(text).length * 7 }; }
}
for (const name of ["setTransform", "clearRect", "fillRect", "beginPath", "roundRect", "rect", "fill", "fillText",
  "stroke", "moveTo", "lineTo", "save", "restore", "clip", "arc", "closePath", "strokeRect"]) {
  Context2D.prototype[name] = function () {};
}

class Element extends Node {
  constructor(doc, tag) {
    super(doc);
    this.localName = tag.toLowerCase();
    this.tagName = tag.toUpperCase();
    this.attributes = new Map();
    this.style = new Style();
    this.classList = new ClassList(this);
    this.dataset = datasetFor(this);
    this.rect = null;
  }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  removeAttribute(name) { this.attributes.delete(name); }
  hasAttribute(name) { return this.attributes.has(name); }
  get id() { return this.getAttribute("id") || ""; }
  set id(value) { this.setAttribute("id", value); }
  get className() { return this.getAttribute("class") || ""; }
  set className(value) { this.setAttribute("class", value); }
  get type() { return (this.getAttribute("type") || "").toLowerCase(); }
  get name() { return this.getAttribute("name") || ""; }
  get tabIndex() { const v = this.getAttribute("tabindex"); return v === null ? -1 : Number(v); }
  set tabIndex(value) { this.setAttribute("tabindex", String(value)); }
  get isContentEditable() { return false; }
  get options() { return this.querySelectorAll("option"); }
  get files() { return this.fileList || null; }
  get value() {
    if (this.localName === "select") {
      const options = this.options;
      const chosen = options.find((o) => o.picked === true)
        || (this.none ? null : options.find((o) => o.hasAttribute("selected")) || options[0]);
      return chosen ? chosen.value : "";
    }
    if (this.localName === "option") return this.getAttribute("value") ?? this.textContent;
    if (this.typed !== undefined) return this.typed;
    if (this.localName === "textarea") return this.textContent;
    return this.getAttribute("value") ?? "";
  }
  set value(v) {
    const text = v === null || v === undefined ? "" : String(v);
    if (this.localName === "select") {
      let found = false;
      for (const o of this.options) {
        o.picked = !found && o.value === text;
        found = found || o.picked;
      }
      this.none = !found;
    } else if (this.localName === "option") {
      this.setAttribute("value", text);
    } else {
      this.typed = text;
    }
  }
  changed() { if (this.localName === "select") this.none = false; }
  get checked() { return this.isChecked !== undefined ? this.isChecked : this.hasAttribute("checked"); }
  set checked(v) { this.isChecked = Boolean(v); }
  focus() { this.ownerDocument.activeElement = this; }
  blur() { if (this.ownerDocument.activeElement === this) this.ownerDocument.activeElement = this.ownerDocument.body; }
  select() {}
  // A browser ignores click() on a disabled control, as it ignores the coach's click.
  click() { if (!this.disabled) this.dispatchEvent(new FakeEvent("click")); }
  scrollIntoView() {}
  getBoundingClientRect() {
    const r = this.rect || {};
    const left = r.left || 0;
    const top = r.top || 0;
    const width = r.width || 0;
    const height = r.height || 0;
    return { left, top, width, height, right: left + width, bottom: top + height, x: left, y: top };
  }
  get clientWidth() { return this.rect ? this.rect.width : 0; }
  get clientHeight() { return this.rect ? this.rect.height : 0; }
  get offsetWidth() { return this.rect ? this.rect.width : 0; }
  matches(selector) { return matches(this, selector); }
  closest(selector) {
    for (let n = this; n instanceof Element; n = n.parentNode) if (n.matches(selector)) return n;
    return null;
  }
  querySelectorAll(selector) {
    const out = [];
    const visit = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) out.push(child);
        visit(child);
      }
    };
    visit(this);
    return out;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  cloneNode(deep = false) {
    const copy = this.ownerDocument.createElement(this.localName);
    for (const [k, v] of this.attributes) copy.setAttribute(k, v);
    if (deep) for (const child of this.childNodes) copy.append(child.cloneNode(true));
    return copy;
  }
  getContext() { return new Context2D(); }
}

for (const prop of ["hidden", "disabled", "open", "controls"]) {
  Object.defineProperty(Element.prototype, prop, {
    get() { return this.hasAttribute(prop); },
    set(v) { if (v) this.setAttribute(prop, ""); else this.removeAttribute(prop); },
  });
}
for (const prop of ["title", "href", "src"]) {
  Object.defineProperty(Element.prototype, prop, {
    get() { return this.getAttribute(prop) || ""; },
    set(v) { this.setAttribute(prop, v); },
  });
}

/** <video>: "loads" any src unless it contains a string in globalThis.videoFails. */
class Video extends Element {
  constructor(doc) {
    super(doc, "video");
    Object.assign(this, { currentTime: 0, duration: NaN, paused: true, videoWidth: 0, videoHeight: 0,
      currentSrc: "", playbackRate: 1, defaultPlaybackRate: 1 });
  }
  get src() { return this.currentSrc; }
  set src(value) {
    this.currentSrc = String(value);
    const fails = (globalThis.videoFails || []).some((part) => this.currentSrc.includes(part));
    realSetTimeout(() => {
      if (fails) {
        this.dispatchEvent(new FakeEvent("error", { bubbles: false }));
        return;
      }
      Object.assign(this, { videoWidth: 1280, videoHeight: 720, duration: 600 });
      this.dispatchEvent(new FakeEvent("loadedmetadata", { bubbles: false }));
    }, 1);
  }
  play() { this.paused = false; this.dispatchEvent(new FakeEvent("play", { bubbles: false })); return Promise.resolve(); }
  pause() { this.paused = true; this.dispatchEvent(new FakeEvent("pause", { bubbles: false })); }
}

class Document extends Node {
  constructor() {
    super(null);
    this.ownerDocument = this;
    this.documentElement = new Element(this, "html");
    this.head = new Element(this, "head");
    this.body = new Element(this, "body");
    this.documentElement.append(this.head, this.body);
    this.adopt(this.documentElement);
    this.title = "";
    this.activeElement = this.body;
    this.fullscreenElement = null;
  }
  createElement(tag) { return tag.toLowerCase() === "video" ? new Video(this) : new Element(this, tag); }
  createElementNS(_ns, tag) { return new Element(this, tag); }
  createTextNode(text) { return new Text(this, text); }
  createDocumentFragment() { return new DocumentFragment(this); }
  getElementById(id) { return this.documentElement.querySelectorAll("*").find((el) => el.getAttribute("id") === id) || null; }
  querySelector(selector) { return this.documentElement.querySelector(selector); }
  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  execCommand() { return false; }
  exitFullscreen() { return Promise.resolve(); }
}

// ------------------------------------------------------------------ fake server
export const server = { routes: [], log: [] };

/** Answer METHOD path (string = exact path, RegExp = test) with a result or a function of the request. */
export function route(method, pattern, handler) {
  server.routes.push({ method, pattern, handler });
}

export const json = (body, status = 200) => ({ status, json: body });
export const fail = (status, code, title, extra = {}) => ({
  status, json: { error: { code, title, message: `${title}.`, hint: null, retryable: false, detail: null, ...extra } },
});

async function answer(method, url, body) {
  server.log.push(`${method} ${url}`);
  const u = new URL(url, "http://scout.test");
  const found = [...server.routes].reverse().find((r) => r.method === method
    && (typeof r.pattern === "string" ? r.pattern === u.pathname : r.pattern.test(u.pathname)));
  if (!found) return fail(404, "NOT_FOUND", `No fake route for ${method} ${u.pathname}`);
  let parsed = body;
  if (typeof body === "string") {
    try { parsed = JSON.parse(body); } catch { parsed = body; }
  }
  const request = { method, url, path: u.pathname, query: Object.fromEntries(u.searchParams), body: parsed };
  return typeof found.handler === "function" ? found.handler(request) : found.handler;
}

const responseText = (r) => (r.text !== undefined ? r.text : r.json !== undefined ? JSON.stringify(r.json) : "");

async function fakeFetch(url, init = {}) {
  const signal = init.signal;
  if (signal && signal.aborted) throw new DOMException("Aborted", "AbortError");
  let pending = answer(init.method || "GET", String(url), init.body);
  if (signal) {
    const aborted = new Promise((_, reject) => signal.addEventListener("abort",
      () => reject(new DOMException("Aborted", "AbortError")), { once: true }));
    pending = Promise.race([pending, aborted]);
  }
  const result = await pending;
  if (result.network) throw new TypeError("Failed to fetch");
  const status = result.status ?? 200;
  const text = responseText(result);
  return { ok: status >= 200 && status < 300, status, text: async () => text };
}

class FakeXHR {
  constructor() { this.upload = {}; this.status = 0; this.responseText = ""; this.headers = {}; }
  open(method, url) { this.method = method; this.url = url; }
  setRequestHeader(name, value) { this.headers[name] = value; }
  send(body) {
    this.aborted = false;
    Promise.resolve(answer(this.method, this.url, body)).then((result) => {
      if (this.aborted) return;
      if (result.network) { this.onerror?.(); return; }
      const size = body && body.size ? body.size : 0;
      this.upload.onprogress?.({ loaded: size, total: size });
      this.status = result.status ?? 200;
      this.responseText = responseText(result);
      this.onload?.();
    });
  }
  abort() {
    if (this.aborted) return;
    this.aborted = true;
    this.onabort?.();
  }
}

function makeStorage() {
  const data = new Map();
  return {
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
    removeItem: (k) => data.delete(k),
    clear: () => data.clear(),
  };
}

function build(doc, node) {
  if (typeof node === "string") return doc.createTextNode(node);
  const [tag, attrs, children] = node;
  const element = doc.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) element.setAttribute(k, v);
  for (const child of children) element.append(build(doc, child));
  return element;
}

/** Build the page body and the browser globals; url is the page address ("/games/g_1"). */
export function boot(body, url) {
  const doc = new Document();
  const win = new Target();
  const location = new URL(url, "http://scout.test");
  Object.assign(win, {
    location: {
      get pathname() { return location.pathname; },
      get search() { return location.search; },
      get hash() { return location.hash; },
      assign(target) { win.navigatedTo = String(target); },
      reload() {},
    },
    history: { replaceState(_state, _title, target) { const next = new URL(target, location); location.pathname = next.pathname; location.search = next.search; } },
    localStorage: makeStorage(),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    confirm: () => globalThis.confirmAnswer ?? true,
    isSecureContext: true,
    devicePixelRatio: 1,
    innerHeight: 800,
    innerWidth: 1280,
    print() {},
  });
  for (const [k, v] of Object.entries(body[1])) doc.body.setAttribute(k, v);
  for (const child of body[2]) doc.body.append(build(doc, child));
  Object.assign(globalThis, {
    window: win,
    document: doc,
    localStorage: win.localStorage,
    Node,
    Element,
    getComputedStyle: (el) => el.style,
    ResizeObserver: class { observe() {} disconnect() {} },
    requestAnimationFrame: (cb) => realSetTimeout(() => cb(performance.now()), 1),
    cancelAnimationFrame: (id) => realClearTimeout(id),
    fetch: fakeFetch,
    XMLHttpRequest: FakeXHR,
    setTimeout: (fn, ms, ...args) => realSetTimeout(fn, Math.min(Number(ms) || 0, 1), ...args),
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { userAgent: "fake", clipboard: { writeText: async (text) => { globalThis.clipboardText = text; } } },
  });
  return { document: doc, window: win };
}

export const $ = (selector) => globalThis.document.querySelector(selector);
export const $$ = (selector) => globalThis.document.querySelectorAll(selector);
export const byId = (id) => globalThis.document.getElementById(id);
export const fire = (el, type, init = {}) => el.dispatchEvent(new FakeEvent(type, init));
export const textOf = (el) => (el ? el.textContent.replace(/\s+/g, " ").trim() : null);
"""

# JS helpers shared by the game-page tests: a Game, a Job and a small GameAnalysis.
GAME_FIXTURES_JS = r"""
export const game = (over = {}) => ({
  id: "g_1", title: "", scouted_team: "Central", other_team: "Lincoln", game_date: null, location: null,
  level: null, notes: null, scouted_color: "dark", team_id_map: { 0: "scouted", 1: "other" }, status: "ready",
  video_filename: "film.mp4", video_size: 1000, video_url: null, has_video: true, has_annotated_video: false,
  has_analysis: true, calibration: null, latest_job_id: null, error: null, display_title: "Central vs Lincoln",
  ...over,
});

export const job = (over = {}) => ({
  id: "j_1", game_id: "g_1", kind: "analyze", status: "queued", stage: "queued", progress: 0, message: "",
  error: null, warnings: [], params: {}, attempts: 0, max_attempts: 3, cancel_requested: false,
  started_at: null, ...over,
});

const split = () => ({ made: 0, attempts: 0, pct: null });
export const line = (over = {}) => ({
  player: { player_id: null, jersey: null, name: null, side: "scouted", match_confidence: 0, label: "Unknown player" },
  minutes_est: null, pts: 0, fgm: 0, fga: 0, tpm: 0, tpa: 0, ftm: 0, fta: 0, oreb: 0, dreb: 0, reb: 0, ast: 0,
  stl: 0, blk: 0, tov: 0, pf: 0, plus_minus: null, fg_pct: null, tp_pct: null, ft_pct: null,
  zones: { paint: split(), mid: split(), three: split(), unknown: split() },
  ...over,
});

export const player = (jersey, name, side = "scouted") => ({
  player_id: `p_${jersey}`, jersey, name, side, match_confidence: 1, label: `#${jersey} ${name}`,
});

export const box = (side, players, over = {}) => ({
  side, team_name: side === "scouted" ? "Central" : "Lincoln", players,
  team_unattributed: line({ player: { name: "Team", side, label: "Team" } }),
  totals: line({ player: { name: "Totals", side, label: "Totals" } }), possessions: 0, points_per_possession: null,
  ...over,
});

export const analysis = (over = {}) => ({
  schema_version: "1.0", game_id: "g_1", generated_at: "2026-01-10T00:00:00Z",
  video: { filename: "film.mp4", fps: 30, width: 1920, height: 1080, frame_count: 18000, duration_s: 600, analysis_fps: 15 },
  pipeline: { name: "synthetic", version: "1" },
  teams: [
    { side: "scouted", name: "Central", team_id: 0, color_rgb: [20, 30, 120], color_name: "navy", score: 0 },
    { side: "other", name: "Lincoln", team_id: 1, color_rgb: [240, 240, 240], color_name: "white", score: 0 },
  ],
  timeline: [], possessions: [], plays: [], shots: [], play_summary: [], track_assignments: [],
  box_scores: [box("scouted", []), box("other", [])],
  data_quality: { homography_available: true, coord_mode: "court", warnings: [], unmatched_jerseys: [] },
  ...over,
});

/** Routes every game-page load needs; tests add or override the ones they care about. */
export function gamePageRoutes(route, json, { gameBody, jobs = [], analysisBody = null } = {}) {
  route("GET", "/api/games/g_1", () => json(typeof gameBody === "function" ? gameBody() : gameBody));
  route("GET", "/api/games/g_1/jobs", () => json(jobs));
  route("GET", "/api/court/landmarks", json({ court: {}, landmarks: {} }));
  route("GET", "/api/health", json({ status: "ok", claude_configured: true, max_upload_bytes: 1e12 }));
  route("GET", "/api/games/g_1/reports", json([]));
  route("GET", "/api/export/fastscout/tables", json(["box"]));
  if (analysisBody) route("GET", "/api/games/g_1/analysis", () => json(analysisBody));
}
"""


def run_page(tmp_path: Path, page: str, url: str, script: str) -> dict:
    """Boot ``page`` at ``url`` in the fake DOM, run ``script`` (an ES module body) and
    return the JSON object it prints last."""
    if NODE is None:
        pytest.skip("node is not installed")
    workdir = tmp_path / "web"
    shutil.copytree(STATIC / "js", workdir / "js")
    (workdir / "package.json").write_text('{"type": "module"}', encoding="utf-8")
    (workdir / "dom.js").write_text(FAKE_DOM_JS, encoding="utf-8")
    (workdir / "fixtures.js").write_text(GAME_FIXTURES_JS, encoding="utf-8")
    (workdir / "page.json").write_text(json.dumps(page_body(page)), encoding="utf-8")
    prelude = (
        'import { readFileSync } from "node:fs";\n'
        'import { boot, route, json, fail, settle, pause, server, $, $$, byId, fire, textOf } from "./dom.js";\n'
        'import { game, job, line, player, box, analysis, gamePageRoutes } from "./fixtures.js";\n'
        f'const page = boot(JSON.parse(readFileSync("page.json", "utf8")), {json.dumps(url)});\n'
    )
    (workdir / "check.js").write_text(prelude + script + "\nprocess.exit(0);\n", encoding="utf-8")
    result = subprocess.run([NODE, "check.js"], cwd=workdir, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    assert lines, f"no output; stderr: {result.stderr}"
    return json.loads(lines[-1])


# ---------------------------------------------------------------------------
# Harness sanity: the game page boots against the fake server
# ---------------------------------------------------------------------------


def test_harness_boots_the_game_page(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
await import("./js/game.js");
await settle();
console.log(JSON.stringify({
  title: textOf(byId("game-title")),
  badge: textOf($(".badge")),
  tabs: byId("analysis-tabs-wrap").hidden,
  error: textOf(byId("page-error")),
}));
""",
    )
    assert out == {"title": "Central vs Lincoln", "badge": "Ready", "tabs": False, "error": ""}


# ---------------------------------------------------------------------------
# Game page header and job panel
# ---------------------------------------------------------------------------


def test_header_badge_follows_job_polling(tmp_path):
    """The badge said "Queued" until the job ended; it must follow the polled job."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
let polls = 0;
gamePageRoutes(route, json, {
  gameBody: game({ status: "queued", has_analysis: false, latest_job_id: "j_1" }),
  jobs: [job({ status: "queued" })],
});
route("GET", "/api/jobs/j_1", () => {
  polls += 1;
  return json(polls < 3 ? job() : job({ status: "running", stage: "gpu_processing", progress: 42 }));
});
await import("./js/game.js");
await settle();
const badge = $("#game-meta .badge");
console.log(JSON.stringify({ text: textOf(badge), cls: badge.className, rerunDisabled: byId("reanalyze-btn").disabled }));
""",
    )
    assert out["text"] == "Processing · 42%"
    assert out["cls"] == "badge badge-processing"
    assert out["rerunDisabled"] is True


def test_stale_refresh_cannot_overwrite_a_newer_one(tmp_path):
    """A slow refresh started before a job finished must not repaint the page as "Queued"
    after the refresh made when the job finished."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
let gameCalls = 0;
let analysisCalls = 0;
const done = job({ id: "j_2", kind: "reanalyze", status: "succeeded", stage: "done", progress: 100 });
gamePageRoutes(route, json, {
  gameBody: () => {
    gameCalls += 1;
    return gameCalls === 2 ? game({ status: "queued", latest_job_id: "j_2" }) : game({ latest_job_id: gameCalls > 2 ? "j_2" : null });
  },
});
route("GET", "/api/games/g_1/jobs", () => json(gameCalls >= 3 ? [done] : []));
route("GET", "/api/games/g_1/analysis", async () => {
  analysisCalls += 1;
  if (analysisCalls === 2) await pause(150); // the refresh made right after "Re-run analysis" is slow
  return json(analysis());
});
route("POST", "/api/games/g_1/jobs", json(job({ id: "j_2", kind: "reanalyze" }), 201));
route("GET", "/api/jobs/j_2", json(done));
await import("./js/game.js");
await settle();
byId("reanalyze-btn").click();
await pause(300);
await settle();
console.log(JSON.stringify({ badge: textOf($("#game-meta .badge")), rerunDisabled: byId("reanalyze-btn").disabled, gameCalls }));
""",
    )
    assert out["gameCalls"] == 3
    assert out["badge"] == "Ready"
    assert out["rerunDisabled"] is False


def test_job_panel_updates_in_place_so_cancel_keeps_focus(tmp_path):
    """Every poll rebuilt the panel: a keyboard user's focus on Cancel was lost every 3 s
    and the whole panel was re-announced by screen readers."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
let polls = 0;
gamePageRoutes(route, json, {
  gameBody: game({ status: "processing", has_analysis: false, latest_job_id: "j_1" }),
  jobs: [job({ status: "running", stage: "gpu_processing", progress: 10 })],
});
route("GET", "/api/jobs/j_1", () => {
  polls += 1;
  const step = Math.min(polls, 6);
  return json(job({ status: "running", stage: "gpu_processing", progress: 10 + step, message: `step ${step}` }));
});
await import("./js/game.js");
await settle(3);
const cancel = $("#job-panel button");
cancel.focus();
const before = polls;
await settle(40);
const details = $("#job-panel .job-details");
console.log(JSON.stringify({
  polled: polls - before,
  sameButton: $("#job-panel button") === cancel,
  focused: page.document.activeElement === cancel,
  details: textOf(details),
  detailsLive: details && details.getAttribute("aria-live"),
  panelLive: byId("job-panel").getAttribute("aria-live"),
}));
""",
    )
    assert out["polled"] >= 3
    assert out["sameButton"] is True
    assert out["focused"] is True
    assert out["details"] == "16% overall · step 6"  # still updated with every poll
    assert out["detailsLive"] == "off"  # ...but not read out every 3 s
    assert out["panelLive"] == "polite"


def test_cancel_request_leaves_the_button_disabled(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, {
  gameBody: game({ status: "processing", has_analysis: false, latest_job_id: "j_1" }),
  jobs: [job({ status: "running", stage: "gpu_processing", progress: 10 })],
});
let cancelled = false;
route("GET", "/api/jobs/j_1", () => json(job({ status: "running", stage: "gpu_processing", progress: 10, cancel_requested: cancelled })));
route("POST", "/api/jobs/j_1/cancel", () => { cancelled = true; return json(job({ status: "running", stage: "gpu_processing", cancel_requested: true })); });
await import("./js/game.js");
await settle(10);
$("#job-panel button").click();
await settle(10);
const button = $("#job-panel button");
console.log(JSON.stringify({ text: textOf(button), disabled: button.disabled }));
""",
    )
    assert out == {"text": "Cancelling…", "disabled": True}


def test_team_choice_buttons_differ_when_both_teams_wear_the_same_colour(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, {
  gameBody: game({ team_id_map: {} }),
  analysisBody: analysis({ teams: [
    { side: "scouted", name: "Central", team_id: 0, color_rgb: [200, 40, 40], color_name: "red", score: 0 },
    { side: "other", name: "Lincoln", team_id: 1, color_rgb: [110, 20, 30], color_name: "red", score: 0 },
  ] }),
});
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ labels: $$("#team-banner button").map(textOf) }));
""",
    )
    assert out["labels"] == ["Red jerseys (lighter)", "Red jerseys (darker)"]


# ---------------------------------------------------------------------------
# Video
# ---------------------------------------------------------------------------


def test_film_added_by_link_plays_its_annotated_copy(tmp_path):
    """A game analysed from a video link has no original file but does have the annotated
    video on the server; the page hid the player entirely."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, {
  gameBody: game({ has_video: false, video_url: "https://example.com/film.mp4", has_annotated_video: true }),
  analysisBody: analysis(),
});
await import("./js/game.js");
await settle();
byId("variant-original").click(); // disabled (no original file): the click does nothing, as in a browser
await settle();
console.log(JSON.stringify({
  playerShown: !byId("player-main").hidden,
  missingShown: !byId("player-missing").hidden,
  src: byId("video").currentSrc,
  originalDisabled: byId("variant-original").disabled,
  requests: server.log.filter((r) => r.includes("/video")),
}));
""",
    )
    assert out["playerShown"] is True
    assert out["missingShown"] is False
    assert out["src"] == "/api/games/g_1/video?variant=annotated"
    assert out["originalDisabled"] is True


def test_original_film_that_cannot_play_falls_back_to_the_annotated_copy(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, { gameBody: game({ has_annotated_video: true }), analysisBody: analysis() });
globalThis.videoFails = ["variant=original"];
await import("./js/game.js");
await settle();
byId("variant-original").click();
await settle();
console.log(JSON.stringify({
  src: byId("video").currentSrc,
  annotatedPressed: byId("variant-annotated").getAttribute("aria-pressed"),
  message: textOf(byId("video-error")),
}));
""",
    )
    assert out["src"] == "/api/games/g_1/video?variant=annotated"
    assert out["annotatedPressed"] == "true"
    assert "annotated copy" in out["message"]


def test_marker_tooltip_stays_inside_the_strip(tmp_path):
    """At 375 px a tooltip near the right end of the marker strip widened the page (455 px)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
await import("./js/game.js");
await settle();
byId("marker-strip").rect = { left: 0, top: 0, width: 330, height: 34 };
byId("marker-tip").rect = { width: 200, height: 20 };
fire(byId("marker-strip"), "mousemove", { clientX: 327 });
console.log(JSON.stringify({ left: byId("marker-tip").style.left, hidden: byId("marker-tip").hidden }));
""",
    )
    assert out == {"left": "230px", "hidden": False}


def test_shot_tooltip_stays_inside_the_chart(tmp_path):
    """At 375 px a corner shot's tooltip ran from x=-100 to x=514."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
const shot = { event_id: "e1", t: 30, side: "scouted", player: player("3", "Smith"), made: true, points: 3,
  is_three: true, zone: "three", subzone: "corner_left", court_xy: [2, 2], half_court_xy: [2, 1], assisted: false, blocked: false };
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ shots: [shot] }) });
await import("./js/game.js");
await settle();
byId("shot-chart").parentElement.rect = { left: 20, top: 0, width: 330, height: 280 };
byId("shot-tip").rect = { width: 300, height: 20 };
const hit = $("#shot-chart .shot-hit");
hit.rect = { left: 22, top: 260, width: 6, height: 6 };
fire(hit, "mouseover");
console.log(JSON.stringify({ left: byId("shot-tip").style.left, text: textOf(byId("shot-tip")) }));
""",
    )
    assert out["left"] == "150px"
    assert out["text"].startswith("#3 Smith")


def test_space_plays_the_film_after_clicking_an_event_time(tmp_path):
    """Chrome keeps focus on a clicked button, so Space "clicked" the event time again
    (re-seeking) instead of playing; keyboard users still activate buttons with Space."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
const event = (id, t) => ({ id, t, frame: t * 30, type: "shot_made", label: "3PT Make", side: "scouted",
  player: player("3", "Smith"), secondary_player: null, possession_side: "scouted", possession_id: 1, points: 3,
  zone: "three", subzone: null, confidence: 0.9, play_id: null, score_scouted: 3, score_other: 0, description: "" });
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ timeline: [event("e1", 30), event("e2", 60)] }) });
await import("./js/game.js");
await settle();
const video = byId("video");
const [first, second] = $$("#timeline-body .time-btn");
fire(first, "mousedown");
first.focus();
fire(first, "click");
const seekedTo = video.currentTime;
const spaceHandled = !fire(first, "keydown", { key: " " });
const playing = !video.paused;
fire(first, "keydown", { key: "Tab" });
second.focus();
const keyboardSpaceHandled = !fire(second, "keydown", { key: " " });
// A clicked analysis tab: ArrowRight moves to the next tab and must not also seek the film.
const tab = byId("tabbtn-shots");
fire(tab, "mousedown");
tab.focus();
const before = video.currentTime;
fire(tab, "keydown", { key: "ArrowRight" });
console.log(JSON.stringify({ seekedTo, spaceHandled, playing, keyboardSpaceHandled,
  tabArrowSeeked: video.currentTime !== before, selectedTab: $("#analysis-tabs [aria-selected=true]").id }));
""",
    )
    assert out["seekedTo"] == 27  # 30 s minus the 3 s pre-roll
    assert out["spaceHandled"] is True
    assert out["playing"] is True
    assert out["keyboardSpaceHandled"] is False  # Tab-focused button: Space stays the button's
    assert out["tabArrowSeeked"] is False
    assert out["selectedTab"] == "tabbtn-plays"


def test_timeline_with_no_events_does_not_blame_the_filters(tmp_path):
    """A film where nothing was detected said "No events match these filters" with no
    filter set, so "Clear filters" looked like the fix."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ timeline: [] }) });
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ text: textOf($("#timeline-body td")), count: textOf(byId("timeline-count")) }));
""",
    )
    assert out["text"].startswith("No events were detected in this film.")
    assert out["count"] == "0 of 0 events"


# ---------------------------------------------------------------------------
# Box score
# ---------------------------------------------------------------------------


def test_box_score_marks_players_who_did_not_play(tmp_path):
    """Same rule as the FastScout paste (no stats and under a minute = DNP)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
const players = [
  line({ player: player("3", "Smith"), minutes_est: 0 }),
  line({ player: player("5", "Lee"), minutes_est: null }),
  line({ player: player("10", "Ortiz"), minutes_est: 0.4, pts: 2, fgm: 1, fga: 1,
    zones: { paint: { made: 1, attempts: 1, pct: 1 }, mid: { made: 0, attempts: 0 }, three: { made: 0, attempts: 0 }, unknown: { made: 0, attempts: 0 } } }),
  line({ player: player("12", "Diaz"), minutes_est: 6.5 }),
];
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ box_scores: [box("scouted", players), box("other", [])] }) });
await import("./js/game.js");
await settle();
const rows = $$("#box-content table.boxscore-table tbody tr").map((tr) => ({
  name: textOf(tr.querySelector("th")), min: textOf(tr.children[2]), dnp: tr.classList.contains("dnp"),
}));
const zoneRows = $$("#box-content table.table-compact tbody tr").map((tr) => textOf(tr.querySelector("th")));
console.log(JSON.stringify({ rows, zoneRows }));
""",
    )
    assert out["rows"] == [
        {"name": "Smith", "min": "DNP", "dnp": True},
        {"name": "Lee", "min": "DNP", "dnp": True},
        {"name": "Ortiz", "min": "0.4", "dnp": False},
        {"name": "Diaz", "min": "6.5", "dnp": False},
        {"name": "Team / unidentified", "min": "–", "dnp": False},
    ]
    assert out["zoneRows"] == ["#10 Ortiz", "#12 Diaz", "Team / unidentified"]


# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

EXPORT_ROUTES_JS = """
page.window.localStorage.setItem("scout.gameTab", JSON.stringify("tabbtn-exports"));
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
route("GET", "/api/games/g_1/export/fastscout.txt", (req) => ({ status: 200, text: `Name\\tPTS\\n${req.query.side} row\\t2` }));
"""


def test_exports_show_paste_warnings_and_team_numbers_for_the_selected_team(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        EXPORT_ROUTES_JS
        + """
route("GET", "/api/games/g_1/export/fastscout-notes", (req) => json({
  warnings: [`${req.query.side}: #23 is not on the roster`],
  team_numbers: `${req.query.side} team numbers\\nFinal score: 50-40`,
}));
await import("./js/game.js");
await settle();
const read = () => ({
  shown: !byId("export-notes").hidden,
  warnings: $$("#export-warnings li").map(textOf),
  numbers: byId("export-team-numbers").value,
  preview: byId("export-preview").value,
});
const first = read();
const side = byId("export-side");
side.value = "other";
fire(side, "change");
await settle();
const second = read();
byId("export-team-copy").click();
await settle();
console.log(JSON.stringify({ first, second, copied: globalThis.clipboardText, status: textOf(byId("export-team-status")) }));
""",
    )
    assert out["first"] == {
        "shown": True,
        "warnings": ["scouted: #23 is not on the roster"],
        "numbers": "scouted team numbers\nFinal score: 50-40",
        "preview": "Name\tPTS\nscouted row\t2",
    }
    assert out["second"]["warnings"] == ["other: #23 is not on the roster"]
    assert out["second"]["numbers"].startswith("other team numbers")
    assert out["copied"] == "other team numbers\nFinal score: 50-40"
    assert out["status"].startswith("Copied")


def test_exports_without_the_notes_route_still_show_the_paste_block(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        EXPORT_ROUTES_JS
        + """
await import("./js/game.js");
await settle();
console.log(JSON.stringify({
  notesShown: !byId("export-notes").hidden,
  error: textOf(byId("export-error")),
  preview: byId("export-preview").value,
}));
""",
    )
    assert out == {"notesShown": False, "error": "", "preview": "Name\tPTS\nscouted row\t2"}


def test_exports_ignore_a_slow_answer_for_the_previous_team(tmp_path):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        EXPORT_ROUTES_JS
        + """
let calls = 0;
route("GET", "/api/games/g_1/export/fastscout.txt", async (req) => {
  calls += 1;
  if (calls === 2) await pause(100); // the "other" block arrives after the coach switched back
  return { status: 200, text: `${req.query.side} block` };
});
await import("./js/game.js");
await settle();
const side = byId("export-side");
side.value = "other";
fire(side, "change");
side.value = "scouted";
fire(side, "change");
await pause(200);
await settle();
console.log(JSON.stringify({ preview: byId("export-preview").value }));
""",
    )
    assert out["preview"] == "scouted block"


# ---------------------------------------------------------------------------
# Upload page
# ---------------------------------------------------------------------------

UPLOAD_ROUTES_JS = """
route("GET", "/api/health", json({ status: "ok", max_upload_bytes: 1e12 }));
route("GET", "/api/games/g_1", json(game({ has_video: false, has_analysis: false, status: "draft" })));
const sessions = {};
let created = 0;
route("POST", "/api/games/g_1/uploads", (req) => {
  created += 1;
  const id = `u_${created}`;
  sessions[id] = { id, game_id: "g_1", filename: req.body.filename, size: req.body.size, received: 0, chunk_size: 4, status: "open" };
  return json(sessions[id], 201);
});
const chunk = (req) => {
  const session = sessions[req.path.split("/")[3]];
  session.received += req.body.size;
  return json(session);
};
route("PUT", /^\\/api\\/uploads\\/u_\\d+\\/chunk$/, chunk);
route("GET", /^\\/api\\/uploads\\/u_\\d+$/, (req) => json(sessions[req.path.split("/")[3]]));
const film = new File([new Uint8Array(10)], "film.mp4", { type: "video/mp4", lastModified: 5 });
const drop = () => fire(byId("dropzone"), "drop", { dataTransfer: { files: [film] } });
const buttons = (id) => $$(`#${id} button`).map(textOf);
const upload = () => ({
  actions: buttons("upload-error"),
  error: textOf($("#upload-error .notice-title")),
  stored: page.window.localStorage.getItem("scout.upload.g_1"),
  pauseShown: !byId("pause-btn").hidden,
  resumeShown: !byId("resume-btn").hidden,
});
"""


def test_upload_rejected_film_offers_another_file_not_resume(tmp_path):
    """"Resume upload" after VIDEO_INVALID re-posted complete and got 409 "already aborted"
    forever; the session is dead, so offer another file and forget it."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + """
route("POST", "/api/uploads/u_1/complete", () => { sessions.u_1.status = "aborted"; return fail(422, "VIDEO_INVALID", "Not a usable video"); });
await import("./js/upload.js");
await settle();
drop();
await settle();
console.log(JSON.stringify(upload()));
""",
    )
    assert out["error"] == "Not a usable video"
    assert out["actions"] == ["Choose another file"]
    assert out["stored"] is None
    assert out["pauseShown"] is False
    assert out["resumeShown"] is False


def test_upload_whose_partial_file_is_gone_can_start_again(tmp_path):
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + """
route("PUT", "/api/uploads/u_1/chunk", () => { sessions.u_1.status = "aborted"; return fail(404, "UPLOAD_NOT_FOUND", "Upload not found"); });
route("POST", "/api/uploads/u_2/complete", json({ game: game(), job: job() }));
await import("./js/upload.js");
await settle();
drop();
await settle();
const first = upload();
$$("#upload-error button").find((b) => textOf(b) === "Upload this file again").click();
await settle();
console.log(JSON.stringify({ first, created, navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["first"]["actions"] == ["Upload this file again", "Choose another file"]
    assert out["first"]["stored"] is None
    assert out["created"] == 2
    assert out["navigatedTo"] == "/games/g_1"


def test_resume_of_a_session_the_server_aborted_starts_over(tmp_path):
    """The network dropped while the server rejected the film: "Resume" found an aborted
    session and looped on 409 "This upload is already aborted"."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + """
let completes = 0;
route("POST", "/api/uploads/u_1/complete", () => {
  completes += 1;
  sessions.u_1.status = "aborted";
  return completes === 1 ? { network: true } : fail(409, "CONFLICT", "Conflict");
});
await import("./js/upload.js");
await settle();
drop();
await settle(30);
const first = upload();
byId("resume-btn").click();
await settle();
console.log(JSON.stringify({ first, second: upload(), completes }));
""",
    )
    assert out["first"]["actions"] == ["Resume upload"]
    assert out["completes"] == 1
    assert out["second"]["actions"] == ["Upload this file again", "Choose another file"]
    assert out["second"]["stored"] is None


SLOW_START_JS = """
let releaseStart;
route("POST", "/api/games/g_1/uploads", async (req) => {
  created += 1;
  const id = `u_${created}`;
  sessions[id] = { id, game_id: "g_1", filename: req.body.filename, size: req.body.size, received: 0, chunk_size: 4, status: "open" };
  if (created === 1) await new Promise((resolve) => { releaseStart = resolve; }); // slow school Wi-Fi
  return json(sessions[id], 201);
});
const deleted = [];
route("DELETE", /^\\/api\\/uploads\\/u_\\d+$/, (req) => { deleted.push(req.path.split("/")[3]); return { status: 204 }; });
const chunks = () => server.log.filter((r) => r.startsWith("PUT ")).length;
"""


def test_upload_cancelled_while_it_is_starting_stays_cancelled(tmp_path):
    """Cancel during "Starting upload…": the session created meanwhile was then used with no
    file ("Something went wrong ... reading 'size'"), stayed stored, and every later file
    was ignored until the page was reloaded."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + SLOW_START_JS
        + """
route("POST", "/api/uploads/u_2/complete", json({ game: game(), job: job() }));
await import("./js/upload.js");
await settle();
drop();
await settle(5);
byId("cancel-btn").click();
releaseStart();
await settle();
const afterCancel = { ...upload(), dropzoneShown: !byId("dropzone").hidden, chunks: chunks() };
drop();
await settle();
console.log(JSON.stringify({ afterCancel, deleted, created, navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["afterCancel"]["error"] is None
    assert out["afterCancel"]["stored"] is None
    assert out["afterCancel"]["dropzoneShown"] is True
    assert out["afterCancel"]["chunks"] == 0
    assert out["deleted"] == ["u_1"]  # the session that arrived after the cancel is discarded too
    assert out["created"] == 2  # the next file uploads normally
    assert out["navigatedTo"] == "/games/g_1"


def test_upload_paused_while_it_is_starting_offers_resume(tmp_path):
    """Pause during "Starting upload…" left the page saying "Paused" with only a Pause button."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + SLOW_START_JS
        + """
route("POST", "/api/uploads/u_1/complete", json({ game: game(), job: job() }));
await import("./js/upload.js");
await settle();
drop();
await settle(5);
byId("pause-btn").click();
releaseStart();
await settle();
const paused = { ...upload(), status: textOf(byId("upload-state")), chunks: chunks() };
byId("resume-btn").click();
await settle();
console.log(JSON.stringify({ paused, navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["paused"]["status"] == "Paused"
    assert out["paused"]["chunks"] == 0
    assert out["paused"]["resumeShown"] is True
    assert out["paused"]["pauseShown"] is False
    assert out["navigatedTo"] == "/games/g_1"


def test_upload_cancelled_while_resume_checks_the_server_shows_no_error(tmp_path):
    """Cancel while "Resume" asked the server what it had: the answer then restarted the
    upload loop with no file and showed "Something went wrong" over the reset page."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + """
route("PUT", /^\\/api\\/uploads\\/u_\\d+\\/chunk$/, () => ({ network: true }));
let slowCheck = false;
let releaseCheck;
route("GET", /^\\/api\\/uploads\\/u_\\d+$/, async (req) => {
  if (slowCheck) await new Promise((resolve) => { releaseCheck = resolve; });
  return json(sessions[req.path.split("/")[3]]);
});
route("DELETE", /^\\/api\\/uploads\\/u_\\d+$/, { status: 204 });
await import("./js/upload.js");
await settle();
drop();
await settle(200);
const failed = upload();
slowCheck = true;
byId("resume-btn").click();
await settle(5);
byId("cancel-btn").click();
await settle(5);
releaseCheck();
await settle();
console.log(JSON.stringify({ failed, after: { ...upload(), dropzoneShown: !byId("dropzone").hidden } }));
""",
    )
    assert out["failed"]["actions"] == ["Resume upload"]
    assert out["after"]["error"] is None
    assert out["after"]["stored"] is None
    assert out["after"]["dropzoneShown"] is True


def test_upload_progress_is_not_a_live_region(tmp_path):
    """The percentage/speed/ETA changed on every progress event inside aria-live: screen
    readers announced it continuously. Only the status text is live."""
    body = page_body("upload.html")
    nodes = []
    todo = [body]
    while todo:
        node = todo.pop()
        nodes.append(node)
        todo.extend(child for child in node[2] if isinstance(child, list))
    stats = next(n for n in nodes if "upload-stats" in n[1].get("class", ""))
    state = next(n for n in nodes if n[1].get("id") == "upload-state")
    assert "aria-live" not in stats[1]
    assert state[1].get("role") == "status"


# ---------------------------------------------------------------------------
# Roster page
# ---------------------------------------------------------------------------

ROSTER_ROUTES_JS = """
route("GET", "/api/games/g_1", json(game({ has_analysis: false })));
const empty = (side) => ({ game_id: "g_1", side, team_name: side === "scouted" ? "Central" : "Lincoln", players: [] });
route("GET", "/api/games/g_1/rosters", json({ scouted: empty("scouted"), other: empty("other") }));
const puts = [];
route("PUT", "/api/games/g_1/rosters/scouted", (req) => {
  puts.push(req.body);
  return json({ ...empty("scouted"), players: req.body.players.map((p, i) => ({ id: `p_${i}`, ...p })) });
});
await import("./js/roster.js");
await settle();
const card = $$("#roster-columns section")[0];
const press = (label) => card.querySelectorAll("button").find((b) => textOf(b) === label).click();
const type = (row, key, value) => {
  const input = card.querySelector(`input[data-i="${row}"][data-key="${key}"]`);
  input.value = value;
  fire(input, "input");
};
"""


def test_roster_jersey_must_be_one_or_two_digits(tmp_path):
    """The server only takes 1-2 digit jerseys; "#5" or "1A" came back as a 422 naming
    "players[0].jersey" and a regex instead of the row the coach typed."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_ROUTES_JS
        + """
press("+ Add player");
type(0, "jersey", "#5");
type(0, "last_name", "Lee");
press("Save roster");
await settle();
const saved = puts.map((body) => body.players.map((p) => p.jersey));
press("+ Add player");
type(1, "jersey", "1A");
press("Save roster");
await settle();
const invalid = card.querySelector(`input[data-i="1"][data-key="jersey"]`).getAttribute("aria-invalid");
console.log(JSON.stringify({ saved, puts: puts.length, error: textOf(card.querySelector(".notice-error p")), invalid }));
""",
    )
    assert out["saved"] == [["5"]]
    assert out["puts"] == 1
    assert out["error"] == 'Row 2: a jersey number is one or two digits (0-99), not "1A".'
    assert out["invalid"] == "true"


def test_roster_name_inputs_are_wide_enough_to_read(tmp_path):
    """At ~1024 px the two rosters sat side by side and every input shrank to ~64 px, so
    "Anderson" was cut off; names now get a minimum width and the rosters stack."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_ROUTES_JS
        + """
press("+ Add player");
const classes = Object.fromEntries(card.querySelectorAll("input[data-key]").map((i) => [i.dataset.key, i.className]));
console.log(JSON.stringify({ classes }));
""",
    )
    classes = out["classes"]
    for key in ("first_name", "last_name", "fastscout_name", "notes"):
        assert classes[key] == "name-input", key
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    name_rule = re.search(r"table input\.name-input\s*\{([^}]*)\}", css)
    assert name_rule and re.search(r"min-width:\s*8rem", name_rule.group(1))
    columns = re.search(r"\.roster-columns\s*\{([^}]*)\}", css).group(1)
    assert re.search(r"grid-template-columns:\s*minmax\(0,\s*1fr\)", columns)


def test_long_film_names_wrap_on_phones():
    """A Hudl file name without spaces or hyphens widened the games list to 609 px at 375 px."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    rule = re.search(r"\.game-meta > span\s*\{([^}]*)\}", css)
    assert rule and "overflow-wrap: anywhere" in rule.group(1)
    body = re.search(r"\nbody\s*\{([^}]*)\}", css).group(1)
    assert "overflow-wrap: break-word" in body


def test_error_details_wrap_instead_of_widening_the_page():
    """A failed job's "Technical details" <pre> holds one long server line (a Modal
    timeout message): opened, it made the page 1261 px wide on a 375 px phone and on a
    1024 px tablet (measured in headless Chrome)."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    rule = re.search(r"(?:^|\n)pre\s*\{([^}]*)\}", css)
    assert rule, "no pre { ... } rule"
    assert re.search(r"white-space:\s*pre-wrap", rule.group(1))
    assert re.search(r"overflow-wrap:\s*anywhere", rule.group(1))


def test_event_type_filter_opens_inside_a_phone_screen():
    """The timeline's "All event types" list opened rightwards from the right-hand filter
    column and ran past the screen: to 380 px at 375 px and 353 px at 320 px (headless
    Chrome), so the whole page scrolled sideways."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    phone = css.split("@media (max-width: 720px)", 1)[1].split("@media", 1)[0]
    rule = re.search(r"\.type-filter\[open\]\s+\.type-options\s*\{([^}]*)\}", phone)
    assert rule, "the phone layout does not move the event-type list"
    assert re.search(r"right:\s*0", rule.group(1)) and re.search(r"left:\s*auto", rule.group(1))


def test_track_reset_after_the_roster_save_already_dropped_its_override(tmp_path):
    """Saving the roster prunes manual assignments to removed players on the server; the
    page then DELETEd the same override, got 404 and never started the re-run."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        """
route("GET", "/api/games/g_1", json(game()));
const smith = { id: "p_1", jersey: "23", first_name: "Sam", last_name: "Smith" };
route("GET", "/api/games/g_1/rosters", json({
  scouted: { game_id: "g_1", side: "scouted", team_name: "Central", players: [smith] },
  other: { game_id: "g_1", side: "other", team_name: "Lincoln", players: [] },
}));
route("GET", "/api/games/g_1/tracks", json({
  assignments: [{ track_id: 7, team_id: 0, side: "scouted", role: "player", player_id: "p_1", jersey: "23", best_read: "23",
    votes: { 23: 1 }, match_score: 1, method: "manual", frames: 300, ignored: false }],
  overrides: [{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }],
}));
route("PUT", "/api/games/g_1/rosters/scouted", (req) => json({ game_id: "g_1", side: "scouted", team_name: "Central", players: req.body.players }));
route("DELETE", "/api/games/g_1/tracks/7", fail(404, "NOT_FOUND", "Not found"));
route("POST", "/api/games/g_1/jobs", json(job({ kind: "reanalyze" }), 201));
await import("./js/roster.js");
await settle();
const card = $$("#roster-columns section")[0];
card.querySelector("button[data-remove]").click(); // Smith was a wrong entry
const select = $("#tracks-body select");
select.value = "";
fire(select, "change");
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({
  error: textOf(byId("tracks-error")),
  rerun: server.log.includes("POST /api/games/g_1/jobs"),
  navigatedTo: page.window.navigatedTo || null,
}));
""",
    )
    assert out == {"error": "", "rerun": True, "navigatedTo": "/games/g_1"}


def test_full_screen_button_works_on_iphone(tmp_path):
    """iPhone Safari has no element full screen, so the button did nothing; fall back to
    the video's own full screen there."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
await import("./js/game.js");
await settle();
let native = 0;
byId("video").webkitEnterFullscreen = () => { native += 1; };
byId("fullscreen-btn").click();
console.log(JSON.stringify({ native }));
""",
    )
    assert out == {"native": 1}


def _label_keys(name: str) -> set[str]:
    """Keys of the object literal ``const <name> = {...}`` in labels.js."""
    text = (STATIC / "js" / "labels.js").read_text(encoding="utf-8")
    body = re.search(rf"const {name} = \{{(.*?)\}};", text, re.S)
    assert body, f"labels.js has no {name}"
    return set(re.findall(r"(?:^|[{,\s])([a-z_]+):\s*\"", body.group(1)))


def test_every_play_role_has_a_label():
    """plays.py names the roles "defender" and "receiver", which had no label, so the Plays
    list read "Ball handler: #3 Smith · defender: #12 Jones"."""
    plays = (REPO / "scout" / "analysis" / "plays.py").read_text(encoding="utf-8")
    literals = re.findall(r"players: dict\[str, int \| None\] = \{([^}]*)\}", plays)
    roles = set(re.findall(r'"([a-z_]+)":', " ".join(literals)))
    assert {"ball_handler", "screener"} <= roles  # the pattern still finds the role literals
    assert not roles - _label_keys("ROLE_LABELS")


@pytest.mark.parametrize(
    ("table", "enum"),
    [
        ("EVENT_TYPE_LABELS", EventType),
        ("EVENT_CATEGORY", EventType),
        ("PLAY_TYPE_LABELS", PlayType),
        ("PLAY_OUTCOME_LABELS", PlayOutcome),
        ("ZONE_LABELS", ShotZone),
        ("STATUS_LABELS", GameStatus),
        ("STAGE_LABELS", JobStage),
        ("JOB_KIND_LABELS", JobKind),
    ],
)
def test_label_tables_cover_the_schema_enums(table, enum):
    """Guard: a new enum value in scout/schemas.py must not reach the coach as a raw code."""
    assert not {member.value for member in enum} - _label_keys(table)


@pytest.mark.parametrize("name", ("index.html", "upload.html", "game.html", "roster.html"))
def test_skip_link_is_visible_when_focused(name):
    """The skip link was .visually-hidden even when focused: keyboard users tabbed onto
    an invisible link."""
    body = page_body(name)
    first_link = next(n for n in body[2] if isinstance(n, list) and n[0] == "a")
    assert first_link[1].get("href") == "#main"
    assert first_link[1].get("class") == "skip-link"
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    focused = re.search(r"\.skip-link:focus\s*\{([^}]*)\}", css)
    assert focused and re.search(r"top:\s*0\.75rem", focused.group(1))
