"""Checks for the browser UI in scout/static (plain HTML + ES modules, no build step).

* every page exists, loads only existing /static files and uses type="module" scripts;
* every element id the JavaScript looks up exists in each page that loads that script;
* nothing is fetched from another host (the server may sit on a school LAN);
* API data never goes through innerHTML (XSS);
* every relative import resolves to a real export;
* JavaScript syntax (``node --check``) and a few pure helpers, when node is installed.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from html.parser import HTMLParser
from pathlib import Path

import pytest

STATIC = Path(__file__).resolve().parent.parent / "scout" / "static"
JS_DIR = STATIC / "js"
PAGES = ("index.html", "upload.html", "game.html", "roster.html")
JS_FILES = sorted(JS_DIR.glob("*.js"))
CSS_FILES = sorted((STATIC / "css").glob("*.css"))
TEXT_FILES = [STATIC / p for p in PAGES] + JS_FILES + CSS_FILES
NODE = shutil.which("node")
needs_node = pytest.mark.skipif(NODE is None, reason="node is not installed")

IMPORT_RE = re.compile(r"""^import\s+(?:\{([^}]*)\}\s+from\s+)?["'](\./[^"']+)["'];?""", re.M)
EXPORT_RE = re.compile(r"^export\s+(?:async\s+)?(?:function\*?|class|const|let|var)\s+([A-Za-z_$][\w$]*)", re.M)
ID_LOOKUP_RE = re.compile(
    r"""(?:getElementById|byId)\(\s*["']([^"'$`]+)["']\s*\)|querySelector(?:All)?\(\s*["']#([\w-]+)["']\s*\)"""
)
JS_CREATED_ID_RE = re.compile(r"""\bid:\s*["']([\w-]+)["']""")
HTML_SINK_RE = re.compile(r"\.(?:innerHTML|outerHTML)\s*\+?=\s*([^;\n]*)")
CONSTANT_STRING_RE = re.compile(r"""^\s*(?:""|''|"[^"$\\]*"|'[^'$\\]*')\s*$""")
URL_RE = re.compile(r"https?://[^\s\"'`)<>]+", re.I)
ALLOWED_URL_PREFIXES = ("http://www.w3.org/",)  # XML namespace identifiers, never fetched


class PageParser(HTMLParser):
    """Collects ids, scripts, stylesheet/icon links and form controls (with label info)."""

    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.scripts: list[dict[str, str | None]] = []
        self.links: list[dict[str, str | None]] = []
        self.urls: list[str] = []
        self.controls: list[dict[str, str | None]] = []
        self.label_targets: set[str] = set()
        self._label_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = dict(attrs)
        if a.get("id"):
            self.ids.append(a["id"])
        for name in ("src", "href", "action", "poster"):
            if a.get(name):
                self.urls.append(a[name])
        if tag == "script":
            self.scripts.append(a)
        elif tag == "link":
            self.links.append(a)
        elif tag == "label":
            self._label_depth += 1
            if a.get("for"):
                self.label_targets.add(a["for"])
        elif tag in ("input", "select", "textarea") and a.get("type") != "hidden":
            self.controls.append({**a, "_in_label": "1" if self._label_depth else None})

    def handle_endtag(self, tag: str) -> None:
        if tag == "label" and self._label_depth:
            self._label_depth -= 1


def parse_page(name: str) -> PageParser:
    parser = PageParser()
    parser.feed((STATIC / name).read_text(encoding="utf-8"))
    return parser


def module_graph(entry: Path) -> list[Path]:
    """The entry module plus everything it imports, transitively."""
    seen: list[Path] = []
    todo = [entry]
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.append(path)
        for _, target in IMPORT_RE.findall(path.read_text(encoding="utf-8")):
            todo.append((path.parent / target).resolve())
    return seen


def page_modules(name: str) -> list[Path]:
    modules: list[Path] = []
    for script in parse_page(name).scripts:
        src = script.get("src") or ""
        modules += module_graph((STATIC / src.removeprefix("/static/")).resolve())
    return modules


# ---------------------------------------------------------------------------
# Pages and assets
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("name", PAGES)
def test_page_exists_with_basics(name):
    text = (STATIC / name).read_text(encoding="utf-8")
    assert text.lstrip().lower().startswith("<!doctype html>")
    assert '<meta name="viewport"' in text
    assert re.search(r"<title>[^<]+</title>", text)
    assert 'lang="en"' in text


@pytest.mark.parametrize("name", PAGES)
def test_scripts_are_modules_with_existing_sources(name):
    page = parse_page(name)
    assert page.scripts, f"{name} loads no script"
    for script in page.scripts:
        assert script.get("type") == "module", f"{name}: script without type=module: {script}"
        src = script.get("src") or ""
        assert src.startswith("/static/js/"), f"{name}: scripts must be absolute /static/js/ paths, got {src!r}"
        assert (STATIC / src.removeprefix("/static/")).is_file(), f"{name}: missing {src}"


@pytest.mark.parametrize("name", PAGES)
def test_static_references_exist_and_are_absolute(name):
    page = parse_page(name)
    for link in page.links:
        href = link.get("href") or ""
        assert href.startswith("/static/"), f"{name}: <link> must use an absolute /static/ path, got {href!r}"
    for url in page.urls:
        if url.startswith("/static/"):
            path = url.split("?")[0].split("#")[0].removeprefix("/static/")
            assert (STATIC / path).is_file(), f"{name} references missing file {url}"
    assert any((link.get("href") or "") == "/static/css/app.css" for link in page.links)


@pytest.mark.parametrize("name", PAGES)
def test_ids_are_unique(name):
    ids = parse_page(name).ids
    duplicates = {i for i in ids if ids.count(i) > 1}
    assert not duplicates, f"{name}: duplicate ids {sorted(duplicates)}"


@pytest.mark.parametrize("name", PAGES)
def test_form_controls_have_labels(name):
    page = parse_page(name)
    for control in page.controls:
        labelled = control.get("_in_label") or control.get("aria-label") or control.get("id") in page.label_targets
        assert labelled, f"{name}: form control without a label: {control}"


@pytest.mark.parametrize("name", PAGES)
def test_js_element_lookups_exist_in_page(name):
    page_ids = set(parse_page(name).ids)
    modules = page_modules(name)
    created = {i for m in modules for i in JS_CREATED_ID_RE.findall(m.read_text(encoding="utf-8"))}
    missing = []
    for module in modules:
        for by_id, by_selector in ID_LOOKUP_RE.findall(module.read_text(encoding="utf-8")):
            element_id = by_id or by_selector
            if element_id not in page_ids and element_id not in created:
                missing.append(f"{module.name}: #{element_id}")
    assert not missing, f"{name} lacks elements used by its scripts: {missing}"


def test_every_js_file_is_used_by_a_page():
    used = {m for page in PAGES for m in page_modules(page)}
    unused = [p.name for p in JS_FILES if p.resolve() not in used]
    assert not unused, f"JavaScript files no page loads: {unused}"


# ---------------------------------------------------------------------------
# Safety rules
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", TEXT_FILES, ids=lambda p: p.name)
def test_no_external_urls(path):
    text = path.read_text(encoding="utf-8")
    external = [u for u in URL_RE.findall(text) if not u.startswith(ALLOWED_URL_PREFIXES)]
    assert not external, f"{path.name} references other hosts: {external}"
    assert not re.search(r"""(?:src|href)\s*=\s*["']//""", text), f"{path.name} has a protocol-relative URL"
    if path.suffix == ".css":
        assert "@import" not in text
        assert not re.search(r"url\(\s*['\"]?(?!data:)[a-z]+:", text, re.I)


@pytest.mark.parametrize("path", JS_FILES, ids=lambda p: p.name)
def test_no_html_injection_sinks(path):
    text = path.read_text(encoding="utf-8")
    for rhs in HTML_SINK_RE.findall(text):
        assert CONSTANT_STRING_RE.match(rhs), f"{path.name}: innerHTML/outerHTML set from a non-constant: {rhs.strip()!r}"
    for sink in ("insertAdjacentHTML", "document.write", "eval(", "new Function("):
        assert sink not in text, f"{path.name} uses {sink}"


@pytest.mark.parametrize("path", JS_FILES, ids=lambda p: p.name)
def test_imports_resolve_to_exports(path):
    for names, target in IMPORT_RE.findall(path.read_text(encoding="utf-8")):
        module = (path.parent / target).resolve()
        assert module.is_file(), f"{path.name} imports missing {target}"
        exports = set(EXPORT_RE.findall(module.read_text(encoding="utf-8")))
        for name in (n.strip().split(" as ")[0] for n in names.split(",") if n.strip()):
            assert name in exports, f"{path.name} imports {name!r} which {target} does not export"


@pytest.mark.parametrize("path", JS_FILES, ids=lambda p: p.name)
def test_no_unused_imports(path):
    text = path.read_text(encoding="utf-8")
    for names, _ in IMPORT_RE.findall(text):
        for name in (n.strip().split(" as ")[-1] for n in names.split(",") if n.strip()):
            assert len(re.findall(rf"\b{re.escape(name)}\b", text)) > 1, f"{path.name} imports {name!r} but never uses it"


def test_css_variables_are_defined():
    css = "\n".join(p.read_text(encoding="utf-8") for p in CSS_FILES)
    defined = set(re.findall(r"(--[\w-]+)\s*:", css))
    used = set(re.findall(r"var\(\s*(--[\w-]+)\s*\)", css))
    assert not used - defined, f"undefined CSS variables: {sorted(used - defined)}"
    assert "prefers-color-scheme: dark" in css
    assert "@media print" in css


# ---------------------------------------------------------------------------
# JavaScript (needs node)
# ---------------------------------------------------------------------------


@needs_node
@pytest.mark.parametrize("path", JS_FILES, ids=lambda p: p.name)
def test_js_syntax(path, tmp_path):
    copy = tmp_path / f"{path.stem}.mjs"
    copy.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    result = subprocess.run([NODE, "--check", str(copy)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr


def run_node(tmp_path: Path, script: str) -> object:
    """Run an ES-module snippet against a copy of scout/static/js; returns its JSON output."""
    workdir = tmp_path / "web"
    shutil.copytree(JS_DIR, workdir / "js")
    (workdir / "package.json").write_text('{"type": "module"}', encoding="utf-8")
    (workdir / "check.js").write_text(script, encoding="utf-8")
    result = subprocess.run([NODE, "check.js"], cwd=workdir, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@needs_node
def test_js_helpers(tmp_path):
    out = run_node(
        tmp_path,
        """
import { formatClock, formatPct } from "./js/ui.js";
import { invert3, applyHomography, halfCourtLines, courtConfig, cornerDepth } from "./js/court.js";
import { lastIndexAtOrBefore, playBannerText } from "./js/player.js";
import { tsvToHtml } from "./js/exports.js";
import { sortLines } from "./js/boxscore.js";
import { jobStageText, landmarkLabel } from "./js/labels.js";
import { errorFromResponse } from "./js/api.js";

const H = [[2, 0.1, 5], [0.05, 3, -2], [0.001, 0.002, 1]];
const inv = invert3(H);
const p = applyHomography(H, 10, 20);
const back = applyHomography(inv, p[0], p[1]);
const line = (j, pts) => ({ player: { jersey: j, label: "#" + j }, pts });
const sorted = sortLines([line("00", 1), line("12", 5), line("0", 9), line("3", 2)], "jersey", "asc").map((l) => l.player.jersey);
const byPts = sortLines([line("1", 4), line("2", 9), line("3", 6)], "pts", "desc").map((l) => l.pts);
const err = errorFromResponse(507, JSON.stringify({ error: { code: "GPU_OOM", title: "GPU ran out of memory", message: "m", hint: "h", retryable: true } }));
const proxy = errorFromResponse(502, "<html>Bad gateway</html>");
console.log(JSON.stringify({
  clock: [formatClock(65), formatClock(3725), formatClock(-3)],
  pct: [formatPct(0.4567), formatPct(null)],
  roundTrip: back.map((v) => Math.round(v * 1e6) / 1e6),
  singular: invert3([[1, 2, 3], [2, 4, 6], [1, 1, 1]]),
  lines: halfCourtLines(courtConfig({})).length,
  depth: cornerDepth(courtConfig({ three_pt_radius_ft: 19.75, three_pt_corner_lateral_ft: 19.75 })),
  idx: [lastIndexAtOrBefore([{ t: 1 }, { t: 5 }, { t: 9 }], 6), lastIndexAtOrBefore([{ t: 1 }], 0.5)],
  banner: playBannerText({ type: "pick_and_roll", players: { ball_handler: { label: "#3 Smith" }, screener: { label: "#22 Jones" } }, attrs: {} }),
  zone: playBannerText({ type: "zone_defense", players: {}, attrs: { zone_shape: "2-3" } }),
  html: tsvToHtml("Name\\tPTS\\n<b>Al</b> & \\"Bo\\"\\t12\\n"),
  sorted, byPts,
  stage: jobStageText({ status: "running", stage: "gpu_processing", progress: 41.6, kind: "analyze" }),
  queued: jobStageText({ status: "queued", stage: "queued", progress: 0, kind: "analyze" }),
  landmark: landmarkLabel("left_ft_line_near"),
  err: [err.info.title, err.status, err.info.retryable],
  proxy: [proxy.info.code, proxy.info.retryable],
}));
""",
    )
    assert out["clock"] == ["1:05", "1:02:05", "0:00"]
    assert out["pct"] == ["45.7%", "–"]
    assert out["roundTrip"] == [10, 20]
    assert out["singular"] is None
    assert out["lines"] >= 8
    assert out["depth"] == pytest.approx(5.25)
    assert out["idx"] == [1, -1]
    assert out["banner"] == "Pick & Roll - #3 Smith / #22 Jones"
    assert out["zone"] == "Zone Defense (2-3)"
    assert out["html"] == "<table><tr><td>Name</td><td>PTS</td></tr><tr><td>&lt;b&gt;Al&lt;/b&gt; &amp; &quot;Bo&quot;</td><td>12</td></tr></table>"
    assert out["sorted"] == ["0", "00", "3", "12"]
    assert out["byPts"] == [9, 6, 4]
    assert out["stage"] == "Analyzing on the GPU (42%)"
    assert out["queued"] == "Waiting for the background worker"
    assert out["landmark"] == "Left end: free-throw line, near elbow"
    assert out["err"] == ["GPU ran out of memory", 507, True]
    assert out["proxy"] == ["SERVER_UNAVAILABLE", True]
