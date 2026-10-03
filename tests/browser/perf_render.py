#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "orjson",
#   "websockets",
# ]
# ///
"""Measure re-render time after a one-character edit of a generated 10,000-line document.

Loads the development harness in headless Chrome, replaces its document with a
generated GitHub-style Markdown file, then repeatedly inserts one character in a
line near the middle and times, inside the page:

  paint      setDocument() returning: markdown-it, sanitizing and patching the
             changed blocks, and the scroll-sync rebuild (forces layout) have all run.
  frame      the next rendered frame after that.
  complete   highlighting, math and diagrams settled (usually nothing to redo).

and, for the same source, markdown-it alone and a full render (markdown-it plus
sanitizing every block), which is what the first render of a file costs. Then it
times inserting two lines near the top, which shifts every block below.
Exits non-zero when the median paint time is over --budget-ms.
"""

from __future__ import annotations

import argparse
import asyncio
import statistics
import sys
from pathlib import Path

import orjson

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "browser"))

from chrome import Chrome  # noqa: E402
from check_render import serve_repo  # noqa: E402


def generate(lines_wanted: int) -> list[str]:
    """Build a document mixing every common block type until it has `lines_wanted` lines."""
    out: list[str] = []
    section = 0
    while len(out) < lines_wanted:
        section += 1
        out += [
            f"## Section {section}: configuration and `options`",
            "",
            f"Paragraph {section} with **bold**, _italic_, `inline code`, a [link](https://example.org/{section})",
            "and a second source line that continues the paragraph with ~~struck~~ words and an emoji :tada:.",
            "",
            f"- item one of section {section}",
            "- item two with `code`",
            "  - nested item",
            "- [ ] a task",
            "- [x] a finished task",
            "",
        ]
        if section % 3 == 0:
            out += [
                "```js",
                f"export function handler{section}(event) {{",
                "  const value = event.detail?.value ?? 0;",
                "  return value * 2;",
                "}",
                "```",
                "",
            ]
        if section % 4 == 0:
            out += [
                "| Key | Value | Notes |",
                "| --- | :---: | ---: |",
                f"| a{section} | 1 | first |",
                f"| b{section} | 2 | second |",
                "",
            ]
        if section % 5 == 0:
            out += ["> [!NOTE]", f"> Inline math $x_{section} + y^2$ inside an alert.", ""]
        if section % 7 == 0:
            out += [f"Footnote reference[^{section}].", "", f"[^{section}]: The note for section {section}.", ""]
    return out[:lines_wanted]


async def measure(url: str, lines: list[str], runs: int) -> dict[str, list[float]]:
    async with Chrome(width=1280, height=900) as chrome:
        page = await chrome.open(url)
        await page.wait_for("document.documentElement.dataset.mpRender === 'complete'", 60)
        payload = orjson.dumps(lines).decode()
        await page.eval(
            f"(() => {{ window.__perfLines = {payload}; "
            "window.__mp.preview.setDocument('big.md', window.__perfLines, 5000); })()"
        )
        await page.wait_for("document.documentElement.dataset.mpRender === 'complete'", 120)
        await asyncio.sleep(1)
        results: dict[str, list[float]] = {
            "paint": [],
            "frame": [],
            "complete": [],
            "markdown-it": [],
            "full render (first paint)": [],
        }
        nodes = 0
        for run in range(runs):
            sample = await page.eval(
                "(async () => { const P = window.__mp.preview; const lines = window.__perfLines; "
                f"const at = 5000 + {run}; lines[at] = lines[at] + 'x'; "
                "const t0 = performance.now(); P.setDocument('big.md', lines); const paint = performance.now() - t0; "
                "await new Promise(r => requestAnimationFrame(() => setTimeout(r, 0))); const frame = performance.now() - t0; "
                "while (document.documentElement.dataset.mpRender !== 'complete') await new Promise(r => setTimeout(r, 1)); "
                "const complete = performance.now() - t0; "
                "const src = lines.join('\\n'); "
                "let t = performance.now(); P.renderer.md.render(src, {}); const md = performance.now() - t; "
                "t = performance.now(); P.renderer.render(src, { path: 'big.md', detailsOpen: true }); const both = performance.now() - t; "
                "return { paint, frame, complete, md, both, nodes: document.getElementById('mp-body').getElementsByTagName('*').length }; })()"
            )
            results["paint"].append(sample["paint"])
            results["frame"].append(sample["frame"])
            results["complete"].append(sample["complete"])
            results["markdown-it"].append(sample["md"])
            results["full render (first paint)"].append(sample["both"])
            nodes = sample["nodes"]
            await asyncio.sleep(0.2)
        # Worst case for block reuse: a line inserted near the top moves the line
        # attributes of every block below it.
        results["paint, line inserted at line 100"] = []
        for _ in range(runs):
            ms = await page.eval(
                "(() => { const P = window.__mp.preview; const lines = window.__perfLines; "
                "lines.splice(100, 0, 'An inserted paragraph.', ''); "
                "const t0 = performance.now(); P.setDocument('big.md', lines); return performance.now() - t0; })()"
            )
            results["paint, line inserted at line 100"].append(ms)
            await asyncio.sleep(0.2)
        print(f"document: {len(lines)} lines, {len(chr(10).join(lines).encode())} bytes, {nodes} rendered elements")
        return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lines", type=int, default=10_000)
    parser.add_argument("--runs", type=int, default=15)
    parser.add_argument("--budget-ms", type=float, default=200.0)
    args = parser.parse_args()
    server, port = serve_repo()
    url = f"http://127.0.0.1:{port}/tests/browser/render/index.html?fixture=other.md&theme=light"
    try:
        results = asyncio.run(measure(url, generate(args.lines), args.runs))
    finally:
        server.shutdown()
    for name, values in results.items():
        print(
            f"{name:>24}: median {statistics.median(values):7.1f} ms  "
            f"min {min(values):7.1f}  max {max(values):7.1f}  (n={len(values)})"
        )
    median_paint = statistics.median(results["paint"])
    if median_paint > args.budget_ms:
        print(f"FAIL median paint {median_paint:.1f} ms is over the {args.budget_ms:.0f} ms budget")
        return 1
    print(f"ok   median paint {median_paint:.1f} ms is within the {args.budget_ms:.0f} ms budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
