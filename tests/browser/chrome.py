"""Drive a throwaway headless Chrome over the DevTools protocol.

Each session gets its own temporary profile directory and its own process, so a
Chrome the user has open is never touched. Console messages, uncaught
exceptions and Content-Security-Policy violations are collected for the whole
lifetime of the page.
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import orjson
import websockets

logger = logging.getLogger(__name__)

CHROME = os.environ.get(
    "MP_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
)

# Runs before any page script and is not subject to the page's CSP, so it can
# record violations even when the page itself is blocked from running.
_RECORDER = """
window.__mp_csp = [];
document.addEventListener('securitypolicyviolation', (e) => {
  window.__mp_csp.push(`${e.violatedDirective} blocked ${e.blockedURI || '(inline)'} at ${e.sourceFile}:${e.lineNumber}`);
});
"""


class ChromeError(RuntimeError):
    """Raised when Chrome cannot be started or a protocol call fails."""


@dataclass
class Page:
    """One page target with its event log."""

    ws: Any
    console: list[str] = field(default_factory=list)
    exceptions: list[str] = field(default_factory=list)
    _ids: itertools.count = field(default_factory=lambda: itertools.count(1))
    _pending: dict[int, asyncio.Future] = field(default_factory=dict)
    _reader: asyncio.Task | None = None

    async def _read(self) -> None:
        async for raw in self.ws:
            msg = orjson.loads(raw)
            if "id" in msg:
                fut = self._pending.pop(msg["id"], None)
                if fut is not None and not fut.done():
                    if "error" in msg:
                        fut.set_exception(ChromeError(str(msg["error"])))
                    else:
                        fut.set_result(msg.get("result", {}))
                continue
            method = msg.get("method")
            params = msg.get("params", {})
            if method == "Runtime.consoleAPICalled":
                text = " ".join(
                    str(a.get("value", a.get("description", ""))) for a in params["args"]
                )
                self.console.append(f"console.{params['type']}: {text}")
            elif method == "Runtime.exceptionThrown":
                details = params["exceptionDetails"]
                exc = details.get("exception", {})
                self.exceptions.append(exc.get("description") or details.get("text", ""))
            elif method == "Log.entryAdded":
                entry = params["entry"]
                self.console.append(f"log.{entry['level']} [{entry['source']}]: {entry['text']}")

    async def call(self, method: str, **params: Any) -> dict:
        """Send one protocol command and wait for its result."""
        msg_id = next(self._ids)
        fut = asyncio.get_running_loop().create_future()
        self._pending[msg_id] = fut
        # DevTools only accepts text frames; orjson returns bytes.
        await self.ws.send(
            orjson.dumps({"id": msg_id, "method": method, "params": params}).decode()
        )
        return await asyncio.wait_for(fut, 60)

    async def eval(self, expression: str) -> Any:
        """Evaluate an expression in the page and return its JSON value."""
        res = await self.call(
            "Runtime.evaluate", expression=expression, returnByValue=True, awaitPromise=True
        )
        if "exceptionDetails" in res:
            raise ChromeError(
                res["exceptionDetails"].get("exception", {}).get("description")
                or res["exceptionDetails"].get("text")
            )
        return res["result"].get("value")

    async def wait_for(self, expression: str, timeout: float) -> Any:
        """Poll `expression` until it is truthy; return its value or raise on timeout."""
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            value = await self.eval(expression)
            if value:
                return value
            if asyncio.get_running_loop().time() > deadline:
                raise TimeoutError(f"timed out after {timeout}s waiting for: {expression}")
            await asyncio.sleep(0.1)

    async def csp_violations(self) -> list[str]:
        """Return CSP violations recorded in the top document."""
        return await self.eval("window.__mp_csp || []")


class Chrome:
    """A headless Chrome process with a private temporary profile."""

    def __init__(self, width: int = 1280, height: int = 900) -> None:
        self.width = width
        self.height = height
        self.profile = Path(tempfile.mkdtemp(prefix="mp-chrome-"))
        self.proc: subprocess.Popen | None = None
        self.pages: list[Page] = []

    async def __aenter__(self) -> Chrome:
        self.proc = subprocess.Popen(
            [
                CHROME,
                "--headless=new",
                f"--user-data-dir={self.profile}",
                "--remote-debugging-port=0",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-gpu",
                "--disable-extensions",
                "--allow-file-access-from-files",
                f"--window-size={self.width},{self.height}",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        port_file = self.profile / "DevToolsActivePort"
        for _ in range(200):
            if port_file.exists() and port_file.read_text().strip():
                break
            await asyncio.sleep(0.05)
        else:
            raise ChromeError("Chrome did not publish DevToolsActivePort")
        port, browser_path = port_file.read_text().splitlines()[:2]
        self.port = int(port)
        self.browser_ws = f"ws://127.0.0.1:{self.port}{browser_path}"
        return self

    async def __aexit__(self, *_: object) -> None:
        for page in self.pages:
            if page._reader:
                page._reader.cancel()
            await page.ws.close()
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)

    async def open(self, url: str) -> Page:
        """Open `url` in a new target with event collection enabled from the first byte."""
        async with websockets.connect(self.browser_ws, max_size=None) as browser:
            await browser.send(
                orjson.dumps(
                    {"id": 1, "method": "Target.createTarget", "params": {"url": "about:blank"}}
                ).decode()
            )
            target_id = orjson.loads(await browser.recv())["result"]["targetId"]
        ws = await websockets.connect(
            f"ws://127.0.0.1:{self.port}/devtools/page/{target_id}", max_size=None
        )
        page = Page(ws)
        page._reader = asyncio.create_task(page._read())
        self.pages.append(page)
        await page.call("Runtime.enable")
        await page.call("Log.enable")
        await page.call("Page.enable")
        await page.call("Page.addScriptToEvaluateOnNewDocument", source=_RECORDER)
        await page.call(
            "Emulation.setDeviceMetricsOverride",
            width=self.width,
            height=self.height,
            deviceScaleFactor=1,
            mobile=False,
        )
        await page.call("Page.navigate", url=url)
        return page
