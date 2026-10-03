#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "orjson",
#   "websockets",
# ]
# ///
"""Check web/sync.js in headless Chrome against a page with known block geometry.

Serves the repository root over HTTP on a free loopback port, loads
tests/browser/sync/index.html (which imports /web/sync.js) and asserts band
positions, scroll positions and option handling. Exits non-zero on any failure.
"""

from __future__ import annotations

import asyncio
import functools
import logging
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar

import orjson

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "browser"))

from chrome import Chrome, Page

TOL = 1.0
# Scroller geometry from tests/browser/sync/index.html: a 600px content box under a
# 13px top padding. The visible height (clientHeight) includes the padding.
CONTENT_TOP = 13
VIEWPORT = 600 + CONTENT_TOP


class Quiet(SimpleHTTPRequestHandler):
    """Static file handler that serves modules as JavaScript and logs nothing."""

    extensions_map: ClassVar[dict[str, str]] = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".js": "text/javascript",
    }

    def log_message(self, format: str, *args: Any) -> None:
        pass


class Checker:
    """Collects pass/fail results with expected and actual values."""

    def __init__(self, page: Page) -> None:
        self.page = page
        self.failures: list[str] = []
        self.passed = 0

    def check(self, name: str, ok: bool, expected: Any, actual: Any) -> None:
        if ok:
            self.passed += 1
            print(f"ok   {name}: {actual}")
        else:
            self.failures.append(name)
            print(f"FAIL {name}: expected {expected}, actual {actual}")

    def near(
        self, name: str, expected: float, actual: float | None, tol: float = TOL
    ) -> None:
        ok = actual is not None and abs(actual - expected) <= tol
        self.check(
            name,
            ok,
            f"{expected:.2f} (+/-{tol})",
            None if actual is None else round(actual, 2),
        )

    async def js(self, expr: str) -> Any:
        return await self.page.eval(expr)

    async def y_of(self, line: int) -> float:
        return await self.js(f"T.yOf({line})")

    async def expect_lines(self, label: str, expected: dict[int, float]) -> None:
        for line, want in expected.items():
            self.near(f"{label}: line {line}", want, await self.y_of(line))


def dumps(value: Any) -> str:
    return orjson.dumps(value).decode()


async def flat_and_gaps(c: Checker) -> None:
    await c.js(
        "T.abs("
        + dumps(
            [
                {"start": 0, "end": 1, "top": 0, "h": 40},
                {"start": 3, "end": 5, "top": 60, "h": 90},
                {"start": 9, "end": 9, "top": 250, "h": 30},
            ]
        )
        + ")"
    )
    await c.expect_lines(
        "flat",
        {
            0: 0,
            1: 20,
            2: 40,
            3: 60,
            4: 90,
            5: 120,
            6: 150,
            7: 150 + 100 / 3,
            8: 150 + 200 / 3,
            9: 250,
            10: 250,
            10_000: 250,
        },
    )
    band = await c.js("T.band()")
    c.near(
        "flat: band in scroller scroll coordinates", 250 + CONTENT_TOP, band["scrollY"]
    )
    c.check(
        "flat: band style top",
        band["styleTop"] == f"{250 + CONTENT_TOP}px",
        f"{250 + CONTENT_TOP}px",
        band["styleTop"],
    )


async def nested(c: Checker) -> None:
    await c.js(
        "T.abs("
        + dumps(
            [
                {
                    "start": 0,
                    "end": 9,
                    "top": 0,
                    "h": 360,
                    "tag": "blockquote",
                    "children": [
                        {"start": 0, "end": 1, "top": 20, "h": 40, "tag": "p"},
                        {
                            "start": 3,
                            "end": 9,
                            "top": 80,
                            "h": 240,
                            "tag": "ul",
                            "children": [
                                {"start": 3, "end": 5, "top": 80, "h": 80, "tag": "li"},
                                {
                                    "start": 6,
                                    "end": 9,
                                    "top": 160,
                                    "h": 160,
                                    "tag": "li",
                                },
                            ],
                        },
                    ],
                },
                {"start": 12, "end": 12, "top": 400, "h": 20},
            ]
        )
        + ")"
    )
    await c.expect_lines(
        "nested",
        {
            0: 20,
            1: 40,
            2: 60,
            3: 80,
            4: 80 + 80 / 3,
            5: 80 + 160 / 3,
            6: 160,
            7: 200,
            8: 240,
            9: 280,
            10: 360,
            11: 380,
            12: 400,
        },
    )
    await c.y_of(9)
    height = (await c.js("T.band()"))["h"]
    c.near(
        "nested: last line of an inner item ends at the item's bottom",
        40,
        height,
        tol=0.5,
    )


HEIGHT_BLOCKS = [
    {"start": 0, "end": 0, "top": 0, "h": 30, "tag": "p"},
    {"start": 2, "end": 7, "top": 50, "h": 120, "tag": "pre"},
    {"start": 10, "end": 59, "top": 200, "h": 25, "tag": "details"},
    {"start": 61, "end": 61, "top": 260, "h": 22, "tag": "p"},
]
# Line -> (band top, band height), relative to the content top.
HEIGHT_EXPECT = {
    0: (0, 30),  # single-line paragraph: its whole height
    1: (30, 20),  # blank line between the paragraph bottom and the code block top
    4: (90, 20),  # line inside a 6-line, 120px code block
    7: (150, 20),  # last line of the code block stops at the block's bottom
    8: (170, 15),  # two-line gap: 30px shared between two lines
    30: (210, 4),  # 50 lines in 25px: raised to the minimum band height
    60: (225, 35),  # gap before the last paragraph
    61: (260, 22),  # last line: the last paragraph's height
    5_000: (260, 22),  # past the table: reuses the last line
}


async def band_heights(c: Checker, label: str) -> None:
    await c.js(f"T.abs({dumps(HEIGHT_BLOCKS)}); T.nextFrames(2)")
    for line, (top, height) in HEIGHT_EXPECT.items():
        await c.y_of(line)
        band = await c.js("T.band()")
        c.near(f"{label} band: line {line} top", top, band["y"])
        c.near(f"{label} band: line {line} height", height, band["h"], tol=0.5)


async def leading_lines(c: Checker) -> None:
    await c.js("T.abs(" + dumps([{"start": 2, "end": 3, "top": 50, "h": 40}]) + ")")
    await c.expect_lines("leading", {0: 50, 1: 50, 2: 50, 3: 70})


async def unordered_and_bad_attrs(c: Checker) -> None:
    await c.js(
        """(() => {
          T.abs([{start: 4, end: 5, top: 100, h: 40}, {start: 0, end: 1, top: 0, h: 40}]);
          const odd = document.createElement('div');
          odd.className = 'blk';
          odd.setAttribute('data-line-start', 'x');
          odd.style.top = '500px'; odd.style.height = '10px';
          T.content.appendChild(odd);
          const noEnd = document.createElement('div');
          noEnd.className = 'blk';
          noEnd.setAttribute('data-line-start', '7');
          noEnd.style.top = '200px'; noEnd.style.height = '10px';
          T.content.appendChild(noEnd);
          T.sync.rebuild();
        })()"""
    )
    await c.expect_lines("attrs", {0: 0, 2: 40, 3: 70, 4: 100, 6: 140, 7: 200, 8: 200})

    # Forged line values: an end before its start is ignored, and with a known line
    # count an out-of-range start neither grows the table nor takes measurable time.
    res = await c.js(
        """(() => {
          T.abs([{start: 0, end: 1, top: 0, h: 40}, {start: 4, end: 5, top: 100, h: 40}]);
          const back = document.createElement('div');
          back.className = 'blk';
          back.setAttribute('data-line-start', '3');
          back.setAttribute('data-line-end', '2');
          back.style.top = '600px'; back.style.height = '10px';
          T.content.appendChild(back);
          const huge = document.createElement('p');
          huge.className = 'blk';
          huge.setAttribute('data-line-start', '2000000000');
          huge.setAttribute('data-line-end', '2000000000');
          huge.style.top = '700px'; huge.style.height = '10px';
          T.content.appendChild(huge);
          const t0 = performance.now();
          T.sync.rebuild(8);
          const ms = performance.now() - t0;
          T.sync.setCursor(7);
          return { ms, band: parseFloat(T.band().styleTop) };
        })()"""
    )
    await c.expect_lines("forged attrs", {0: 0, 2: 40, 3: 70, 4: 100})
    # Latency bounds are 10x the local measurement: CI runners are shared and
    # throttled, and the point is "does not size arrays from the attribute".
    c.check("forged attrs: huge start rebuilds quickly", res["ms"] < 500, "< 500 ms", round(res["ms"], 2))
    c.near("forged attrs: past-the-end cursor uses the last real line", 120 + CONTENT_TOP, res["band"])
    res = await c.js(
        """(() => {
          const t0 = performance.now();
          T.sync.rebuild(Number.MAX_SAFE_INTEGER);
          return performance.now() - t0;
        })()"""
    )
    c.check("forged attrs: line count is capped at the file-size limit", res < 500, "< 500 ms", round(res, 2))


async def details(c: Checker) -> None:
    html = (
        '<div data-line-start="0" data-line-end="0" style="height:40px"></div>'
        '<details id="d" data-line-start="2" data-line-end="6"><summary>S</summary>'
        '<div id="inner" data-line-start="3" data-line-end="4" style="height:100px"></div></details>'
        '<div data-line-start="8" data-line-end="8" style="height:40px"></div>'
    )
    await c.js(f"T.flow({dumps(html)})")
    vis = await c.js("document.getElementById('inner').checkVisibility()")
    c.check("details: hidden child reports not visible", vis is False, False, vis)
    await c.expect_lines(
        "details closed", {2: 40, 3: 40 + 30 / 5, 4: 40 + 60 / 5, 7: 70, 8: 70}
    )

    stripped = html.replace(' data-line-start="2" data-line-end="6"', "")
    await c.js(f"T.flow({dumps(stripped)})")
    await c.expect_lines(
        "details closed, unannotated",
        {1: 40, 3: 40 + 30 * 2 / 7, 4: 40 + 30 * 3 / 7, 8: 70},
    )

    # Opening the details resizes #content; the observer must rebuild and move the band.
    await c.js(
        "T.sync.setConfig({scroll: {disable: true}}); T.sync.setCursor(3); document.getElementById('d').open = true"
    )
    try:
        await c.page.wait_for("Math.abs(T.band().y - 70) < 1", 3)
        got = await c.js("T.band().y")
    except TimeoutError:
        got = await c.js("T.band().y")
    c.near("details opened: observer rebuild moves band to inner block", 70, got)


async def band_origin(c: Checker) -> None:
    blocks = [{"start": i, "end": i, "top": i * 100, "h": 100} for i in range(50)]
    await c.js("T.wrap()")
    try:
        await c.js(f"T.abs({dumps(blocks)}); T.nextFrames(2)")
        res = await c.js(
            "T.scroller.scrollTop = 777; T.sync.rebuild(); T.sync.setConfig({scroll: {disable: true}});"
            "T.sync.setCursor(12); T.band()"
        )
        # Content starts below the scroller padding, the wrapper margin, border and padding.
        content_top = CONTENT_TOP + 20 + 3 + 7
        c.near("offset containing block: band on line", 1200, res["y"])
        c.near("offset containing block: scroll y", content_top + 1200, res["scrollY"])
        await c.js("T.sync.setConfig({}); T.sync.setCursor(30)")
        got = await wait_scroll(c, content_top + 3000 - VIEWPORT * 0.35)
        c.near(
            "offset containing block: scrollTop",
            content_top + 3000 - VIEWPORT * 0.35,
            got,
        )
    finally:
        await c.js("T.unwrap()")


async def empty(c: Checker) -> None:
    for label, setup in (
        ("empty document", "T.empty()"),
        ("no annotated elements", "T.flow('<p style=\"height:900px\">x</p>')"),
    ):
        res = await c.js(
            f"""(() => {{
              {setup};
              T.scroller.scrollTop = 0;
              T.sync.setCursor(5);
              T.sync.rebuild();
              T.sync.setCursor(0);
              return {{display: T.band().display, scrollTop: T.scroller.scrollTop}};
            }})()"""
        )
        c.check(
            f"{label}: band hidden, no scroll",
            res == {"display": "none", "scrollTop": 0},
            {"display": "none", "scrollTop": 0},
            res,
        )


def target(line_y: float, pct: float) -> float:
    return CONTENT_TOP + line_y - VIEWPORT * pct / 100


async def wait_scroll(c: Checker, want: float) -> float:
    try:
        await c.page.wait_for(f"Math.abs(T.scroller.scrollTop - {want}) < 1", 5)
    except TimeoutError:
        pass
    return await c.js("T.scroller.scrollTop")


async def scrolling(c: Checker) -> None:
    blocks = [{"start": i, "end": i, "top": i * 100, "h": 100} for i in range(400)]
    await c.js(f"T.abs({dumps(blocks)}); T.nextFrames(2)")

    res = await c.js("T.sync.setConfig({}); T.sync.setCursor(10); T.scroller.scrollTop")
    c.check("smooth: short jump does not land synchronously", res == 0, 0, res)
    c.near(
        "smooth: scrollTop at top_offset_pct 35",
        target(1000, 35),
        await wait_scroll(c, target(1000, 35)),
    )

    res = await c.js("T.sync.setCursor(200); T.scroller.scrollTop")
    c.near("instant: long jump lands synchronously", target(20_000, 35), res)

    await c.js("T.sync.setConfig({scroll: {top_offset_pct: 50}})")
    c.near(
        "config: new top_offset_pct re-applies",
        target(20_000, 50),
        await wait_scroll(c, target(20_000, 50)),
    )

    res = await c.js(
        "T.sync.suppressNextScroll(); T.sync.setCursor(140); T.scroller.scrollTop"
    )
    c.near("suppress: a cursor move is never suppressed", target(14_000, 50), res)

    res = await c.js(
        "T.sync.setCursor(null); ({d: T.band().display, s: T.scroller.scrollTop})"
    )
    c.check("null cursor: band hidden", res["d"] == "none", "none", res["d"])
    c.near("null cursor: no scroll", target(14_000, 50), res["s"])
    res = await c.js("T.sync.setCursor(90); T.scroller.scrollTop")
    c.near("null cursor: next cursor move scrolls", target(9_000, 50), res)

    res = await c.js(
        "T.sync.setConfig({scroll: {disable: true, top_offset_pct: 50}}); T.sync.setCursor(300);"
        "T.nextFrames(3).then(() => ({s: T.scroller.scrollTop, b: T.band()}))"
    )
    c.near("scroll.disable: no scroll", target(9_000, 50), res["s"])
    c.check(
        "scroll.disable: band shown",
        res["b"]["display"] == "block",
        "block",
        res["b"]["display"],
    )
    c.near("scroll.disable: band moves", 30_000, res["b"]["y"])

    res = await c.js(
        "T.sync.setConfig({cursor_line: {disable: true, color: '#c86414', opacity: 0.2}, scroll: {top_offset_pct: 35}});"
        "T.sync.setCursor(300); ({s: T.scroller.scrollTop, b: T.band()})"
    )
    c.check(
        "cursor_line.disable: band hidden",
        res["b"]["display"] == "none",
        "none",
        res["b"]["display"],
    )
    c.near("cursor_line.disable: still scrolls", target(30_000, 35), res["s"])

    res = await c.js(
        "T.sync.setConfig({cursor_line: {color: '#c86414', opacity: 0.2}}); T.band()"
    )
    c.check(
        "cursor_line color and opacity",
        res["display"] == "block"
        and res["background"].startswith("rgb(200, 100, 20)")
        and res["opacity"] == "0.2",
        "block, rgb(200, 100, 20), 0.2",
        (res["display"], res["background"], res["opacity"]),
    )

    res = await c.js(
        "T.sync.destroy(); T.sync.setCursor(5); T.sync.rebuild(); ({d: T.band().display})"
    )
    c.check("destroy: inert afterwards", res["d"] == "none", "none", res["d"])


SUPPRESS_HTML = (
    '<details id="dA" data-line-start="0" data-line-end="2"><summary>A</summary>'
    '<div style="height:500px"></div></details>'
    '<details id="dB" data-line-start="3" data-line-end="5"><summary>B</summary>'
    '<div style="height:300px"></div></details>'
    '<details id="dZ" data-line-start="6" data-line-end="6"><summary>Z</summary></details>'
    + "".join(
        f'<div data-line-start="{8 + i}" data-line-end="{8 + i}" style="height:100px"></div>'
        for i in range(200)
    )
)
# Three closed details of 30px each precede the blocks; line 8 + i starts at 90 + 100 i.
SUPPRESS_LINE = 28
SUPPRESS_Y = 90 + 100 * (SUPPRESS_LINE - 8)
# Longer than the suppression window in web/sync.js.
PAST_WINDOW_MS = 600


async def suppression(c: Checker) -> None:
    await c.js(f"T.flow({dumps(SUPPRESS_HTML)}); T.nextFrames(2)")
    await c.js(f"T.sync.setConfig({{}}); T.sync.setCursor({SUPPRESS_LINE})")
    home = target(SUPPRESS_Y, 35)
    c.near(
        "suppress setup: cursor line scrolled into place",
        home,
        await wait_scroll(c, home),
    )

    # A toggle that grows the content: its re-scroll is skipped exactly once.
    res = await c.js(
        """(async () => {
          const t0 = performance.now();
          const s0 = T.scroller.scrollTop;
          T.sync.suppressNextScroll();
          document.getElementById('dA').open = true;
          await T.nextFrames(3);
          const s1 = T.scroller.scrollTop, y1 = T.band().y;
          document.getElementById('dB').open = true;
          await T.nextFrames(1);
          return {s0, s1, y1, elapsed: performance.now() - t0};
        })()"""
    )
    c.near("suppress toggle: re-scroll skipped", res["s0"], res["s1"])
    c.near("suppress toggle: band follows the layout", SUPPRESS_Y + 500, res["y1"])
    want = target(SUPPRESS_Y + 800, 35)
    # The "only one skipped" case needs the second toggle inside sync.js's 400 ms
    # suppression window; on a runner too slow for that the case proves nothing,
    # so it is reported instead of failed.
    if res["elapsed"] < 400:
        c.near(
            "suppress toggle: only one re-scroll skipped", want, await wait_scroll(c, want)
        )
    else:
        print(
            f"note suppress toggle: only-one-skipped case not run, the toggles took "
            f"{res['elapsed']:.0f} ms (window 400 ms)"
        )
        await wait_scroll(c, want)

    await c.js(
        "document.getElementById('dA').open = false; document.getElementById('dB').open = false"
    )
    c.near(
        "suppress reset: unsuppressed toggles re-scroll",
        home,
        await wait_scroll(c, home),
    )

    # A toggle that does not change the height leaves nothing behind once the window ends.
    res = await c.js(
        """(async () => {
          const h0 = T.content.offsetHeight;
          T.sync.suppressNextScroll();
          document.getElementById('dZ').open = true;
          await T.nextFrames(3);
          return {h0, h1: T.content.offsetHeight};
        })()"""
    )
    c.check(
        "no-resize toggle: content height unchanged",
        res["h0"] == res["h1"],
        res["h0"],
        res["h1"],
    )
    await asyncio.sleep(PAST_WINDOW_MS / 1000)
    await c.js(f"T.sync.setCursor({SUPPRESS_LINE + 2})")
    want = target(SUPPRESS_Y + 200, 35)
    c.near(
        "no-resize toggle: later cursor move scrolls", want, await wait_scroll(c, want)
    )

    await c.js(
        "T.sync.suppressNextScroll(); document.getElementById('dZ').open = false"
    )
    await asyncio.sleep(PAST_WINDOW_MS / 1000)
    await c.js("T.scroller.scrollTop -= 150; T.sync.rebuild()")
    c.near(
        "no-resize toggle: later layout re-scroll happens",
        want,
        await wait_scroll(c, want),
    )

    res = await c.js(f"T.sync.suppressNextScroll(); T.sync.setCursor({SUPPRESS_LINE})")
    c.near(
        "suppress window: cursor move inside it still scrolls",
        home,
        await wait_scroll(c, home),
    )

    # Two toggles in the same frame, then two in consecutive frames.
    res = await c.js(
        """(async () => {
          const s0 = T.scroller.scrollTop;
          T.sync.suppressNextScroll();
          document.getElementById('dA').open = true;
          T.sync.suppressNextScroll();
          document.getElementById('dB').open = true;
          await T.nextFrames(3);
          const same = {s: T.scroller.scrollTop, y: T.band().y};
          T.sync.suppressNextScroll();
          document.getElementById('dA').open = false;
          await T.nextFrames(3);
          T.sync.suppressNextScroll();
          document.getElementById('dB').open = false;
          await T.nextFrames(3);
          return {s0, same, apart: {s: T.scroller.scrollTop, y: T.band().y}};
        })()"""
    )
    c.near("two toggles, same frame: no re-scroll", res["s0"], res["same"]["s"])
    c.near("two toggles, same frame: band follows", SUPPRESS_Y + 800, res["same"]["y"])
    c.near("two toggles, separate frames: no re-scroll", res["s0"], res["apart"]["s"])
    c.near("two toggles, separate frames: band follows", SUPPRESS_Y, res["apart"]["y"])


async def document_scroller(c: Checker) -> None:
    viewport = await c.js("document.scrollingElement.clientHeight")
    top = 50

    def doc_target(y: float, pct: float) -> float:
        return top + y - viewport * pct / 100

    blocks = [{"start": i, "end": i, "top": i * 100, "h": 100} for i in range(400)]
    await c.js(f"T.abs({dumps(blocks)}); T.nextFrames(2)")
    await c.expect_lines("document scroller", {0: 0, 5: 500, 399: 39_900, 500: 39_900})
    res = await c.js("T.band()")
    c.check(
        "document scroller: band shown over [hidden]",
        res["display"] == "block",
        "block",
        res["display"],
    )
    c.near("document scroller: band in page coordinates", top + 39_900, res["scrollY"])

    res = await c.js(
        "T.sync.setCursor(null); T.sync.setConfig({}); window.scrollTo(0, 0);"
        "T.sync.setCursor(10); window.scrollY"
    )
    c.check("document scroller: short jump is smooth", res == 0, 0, res)
    c.near(
        "document scroller: scrollY at top_offset_pct 35",
        doc_target(1000, 35),
        await wait_scroll(c, doc_target(1000, 35)),
    )
    res = await c.js("T.sync.setCursor(300); window.scrollY")
    c.near("document scroller: long jump is instant", doc_target(30_000, 35), res)

    res = await c.js("window.scrollTo(0, 0); T.sync.rebuild(); window.scrollY")
    c.near("document scroller: rebuild re-scrolls", doc_target(30_000, 35), res)

    res = await c.js(
        "window.scrollTo(0, 100); T.sync.suppressNextScroll(); T.sync.rebuild(); window.scrollY"
    )
    c.near("document scroller: suppressed layout re-scroll", 100, res)

    res = await c.js(
        "T.sync.setConfig({scroll: {disable: true}}); T.sync.setCursor(200);"
        "({s: window.scrollY, y: T.band().y})"
    )
    c.near("document scroller: scroll.disable keeps position", 100, res["s"])
    c.near("document scroller: scroll.disable moves band", 20_000, res["y"])


async def large(c: Checker) -> dict[str, Any]:
    n = 10_000
    res = await c.js(f"T.big({n})")
    runs = res["runs"]
    c.check(
        "10k: rebuild under 2000 ms",
        max(runs) < 2000,
        "< 2000 ms",
        [round(r, 2) for r in runs],
    )
    line = 3 * 7_000 + 1
    want = await c.js(
        "(() => { const p = T.content.children[7000]; return p.getBoundingClientRect().top - T.content.getBoundingClientRect().top + 10; })()"
    )
    c.near("10k: second line of block 7000", want, await c.y_of(line))
    return res


async def run(base: str) -> int:
    async with Chrome(width=1280, height=900) as chrome:
        page = await chrome.open(f"{base}/tests/browser/sync/index.html")
        await page.wait_for("window.__harnessReady === true", 10)
        c = Checker(page)
        await flat_and_gaps(c)
        await nested(c)
        await band_heights(c, "element scroller")
        await leading_lines(c)
        await unordered_and_bad_attrs(c)
        await details(c)
        await band_origin(c)
        await empty(c)
        await scrolling(c)
        await suppression(c)
        perf = await large(c)

        doc = await chrome.open(f"{base}/tests/browser/sync/document.html")
        await doc.wait_for("window.__harnessReady === true", 10)
        c.page = doc
        await document_scroller(c)
        await band_heights(c, "document scroller")

        for name, p in (("index.html", page), ("document.html", doc)):
            for exc in p.exceptions:
                c.check(f"{name}: page exceptions", False, "none", exc)
            if not p.exceptions:
                c.check(f"{name}: page exceptions", True, "none", "none")
        print(
            f"\n10,000-block rebuild: {', '.join(f'{r:.2f}' for r in perf['runs'])} ms "
            f"(5 runs); setCursor: {perf['perMove'] * 1000:.2f} us/move"
        )
        print(f"{c.passed} passed, {len(c.failures)} failed")
        return 1 if c.failures else 0


def main() -> int:
    logging.basicConfig(level=logging.INFO)
    handler = functools.partial(Quiet, directory=str(REPO))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        return asyncio.run(run(f"http://127.0.0.1:{server.server_address[1]}"))
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
