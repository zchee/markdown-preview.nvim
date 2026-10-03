#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "orjson",
#   "websockets",
# ]
# ///
"""Render tests/fixtures/github-features.md in headless Chrome and assert on the DOM.

Without --url, the repository root is served over HTTP on a free loopback port and
the development harness (tests/browser/render/index.html, contract CSP as a meta
tag) renders the fixture. With --url, the given page is checked instead, e.g. a
running preview server whose current file is the fixture. Exits 1 and lists every
failed check when anything is missing.
"""

from __future__ import annotations

import argparse
import asyncio
import functools
import logging
import subprocess
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "browser"))

import orjson  # noqa: E402
from chrome import Chrome  # noqa: E402

logger = logging.getLogger("check_render")

# Each entry is a JS expression evaluating to [ok, detail] inside the page, with
# `B` the rendered body and `q`/`qa` querySelector/querySelectorAll on it.
CHECKS: dict[str, str] = {
    "table with header row": "[qa('table').length >= 4 && qa('table thead th').length >= 2, qa('table').length]",
    "table column alignment uses align=": "[q('th[align=center]') !== null && q('td[align=right]') !== null, qa('[align]').length]",
    "escaped pipe in table cell": "[qa('td').some(td => td.textContent.trim() === '|'), '']",
    "disabled task-list checkboxes": (
        "[qa('input.task-list-item-checkbox[type=checkbox]').length === 4 && "
        "qa('input.task-list-item-checkbox').every(i => i.disabled) && "
        "qa('input.task-list-item-checkbox:checked').length === 1, qa('input').length]"
    ),
    "task text keeps escaped parenthesis": "[qa('li.task-list-item').some(li => li.textContent.includes('(Optional) Open')), '']",
    "strikethrough with ~~ and ~": (
        "[qa('del').some(d => d.textContent === 'This was mistaken text') && "
        "qa('del').some(d => d.textContent === 'this uses a single tilde'), qa('del').map(d => d.textContent).join('|')]"
    ),
    "sub, sup, ins, kbd": "[['sub','sup','ins','kbd'].every(t => q(t)), '']",
    "footnote references": "[q('sup a[data-footnote-ref][href=\"#fn-1\"]') !== null && q('sup a[data-footnote-ref][href=\"#fn-2\"]') !== null, qa('[data-footnote-ref]').length]",
    "footnote list with back-references": (
        "[q('section.footnotes[data-footnotes] li#user-content-fn-1') !== null && "
        "q('a.data-footnote-backref[href=\"#fnref-1\"]') !== null && "
        "q('#user-content-fnref-1') !== null && q('section.footnotes li#user-content-fn-2 br') !== null, "
        "q('section.footnotes')?.outerHTML.slice(0, 200)]"
    ),
    "five alert types": (
        "[['note','tip','important','warning','caution'].every(t => q('div.markdown-alert.markdown-alert-' + t + ' > p.markdown-alert-title')), "
        "qa('.markdown-alert').map(e => e.className).join('|')]"
    ),
    "alert icon drawn": "[getComputedStyle(q('.markdown-alert-note .markdown-alert-title'), '::before').maskImage.startsWith('url'), '']",
    "all math typeset by MathJax": (
        "[qa('[data-mp-kind=math]').length >= 12 && qa('[data-mp-kind=math]').every(m => m.querySelector('mjx-container svg')), "
        "qa('[data-mp-kind=math]').length + ' placeholders, ' + qa('[data-mp-kind=math] mjx-container').length + ' typeset']"
    ),
    "$a_1 * b_2$ is math, not emphasis": (
        "(() => { const p = qa('p').find(p => p.textContent.includes('Emphasis characters stay inside math')); "
        "return [!!p && !p.querySelector('em') && p.querySelectorAll('mjx-container').length === 2, p?.innerHTML.slice(0, 160)] })()"
    ),
    "inline $$ after a backslash break is display math": (
        "(() => { const p = qa('p').find(p => p.textContent.includes('Cauchy-Schwarz Inequality')); "
        "return [!!p && p.querySelector('br') !== null && p.querySelector('mjx-container[display=true]') !== null, ''] })()"
    ),
    "$$ block, ```math and $`…`$ forms": (
        "[qa('div[data-mp-kind=math] mjx-container[display=true]').length >= 2 && "
        "qa('p').some(p => p.textContent.includes('dollar-backtick') && p.querySelector('mjx-container')), '']"
    ),
    "<span>$</span> stays text, $100/2$ is math": (
        "(() => { const p = qa('p').find(p => p.textContent.startsWith('To split')); "
        "return [!!p && p.querySelectorAll('mjx-container').length === 1 && p.querySelector('span:not([data-mp-kind])')?.textContent === '$', p?.innerHTML.slice(0, 200)] })()"
    ),
    "mermaid diagram rendered to SVG": "[q('[data-mp-kind=mermaid] svg') !== null && !q('.mp-mermaid-error'), q('[data-mp-kind=mermaid]')?.outerHTML.slice(0, 120)]",
    "code highlighted with pl-* classes": (
        "[['ruby','js','lua'].every(l => q('div.highlight.highlight-source-' + l + ' pre span[class^=pl-]')) && "
        "qa('.highlight pre span[class^=pl-]').length > 15, qa('.highlight').map(h => h.className).join('|')]"
    ),
    "geojson stays a code block": "[q('div.highlight[data-mp-lang=geojson] pre') !== null && !q('div.highlight[data-mp-lang=geojson] svg'), '']",
    "plain fenced code without language": "[qa('pre > code').some(c => c.textContent.startsWith('git status')), '']",
    "quadruple fence shows triple backticks": "[qa('pre > code').some(c => c.textContent.startsWith('```')), '']",
    "colour models stay plain inline code": "[qa('code').some(c => c.textContent === '#0969DA' && c.children.length === 0), '']",
    "heading ids follow GitHub's rules": (
        "(() => { const ids = qa('h1,h2,h3,h4,h5,h6').map(h => h.id); "
        "const want = ['user-content-github-markdown-feature-fixture', 'user-content-sample-section', "
        "'user-content-thisll-be-a-helpful-section-about-the-greek-letter-θ', "
        "'user-content-this-heading-is-not-unique-in-the-file', 'user-content-this-heading-is-not-unique-in-the-file-1', "
        "'user-content-the-picture-element']; "
        "return [want.every(w => ids.includes(w)), want.filter(w => !ids.includes(w)).join(', ') || ids.slice(0, 6).join(', ')] })()"
    ),
    "heading anchor links": "[q('h2#user-content-sample-section > a.anchor[href=\"#sample-section\"] .octicon-link') !== null, '']",
    "data-line-start on blocks": (
        "(() => { const authored = (e) => e.id.startsWith('user-content-') || ['IMG', 'DETAILS', 'PICTURE', 'SECTION', 'A', 'HR'].includes(e.tagName) || (e.classList.contains('highlight') && !e.dataset.mpKind); "
        "const missing = [...B.children].filter(e => !authored(e) && !e.hasAttribute('data-line-start')); "
        "return [qa('[data-line-start]').length > 80 && missing.length === 0 && q('h1')?.dataset.lineStart === '0', "
        "missing.map(e => e.tagName + ':' + e.textContent.slice(0, 30)).join(' | ')] })()"
    ),
    "data-line-end is inclusive": "[q('h1').dataset.lineEnd === '0', q('h1').dataset.lineEnd]",
    "emoji shortcodes": "[B.textContent.includes('\\u{1F44D}') && B.textContent.includes('\\u{1F389}'), '']",
    "autolinks for scheme and www. only": (
        "[q('a[href=\"https://github.com\"]') !== null && q('a[href=\"http://www.github.com\"]') !== null && "
        "!qa('a').some(a => a.textContent === 'example.com'), '']"
    ),
    "external links open in a new tab": "[q('a[href=\"https://pages.github.com/\"][target=_blank][rel=\"noreferrer noopener\"]') !== null, '']",
    "relative Markdown link opens through api/open": "[q(`a[data-mp-open=\"${D}other.md\"][href=\"file/${D}other.md\"]`) !== null && q(`a[data-mp-open=\"${D}github-features.md\"]`) !== null, '']",
    "relative media link served from file/": "[q(`a[href=\"file/${D}images/swatch-light.png\"][target=_blank]`) !== null, '']",
    "link escaping the root has no href": "[qa('a').some(a => a.textContent === 'outside the root' && !a.hasAttribute('href')), '']",
    "relative image mapped to file/": "[q('img[alt=Swatch]')?.getAttribute('src') === `file/${D}images/swatch-light.png` && q('img[alt=Swatch]').complete && q('img[alt=Swatch]').naturalWidth === 8, q('img[alt=Swatch]')?.getAttribute('src')]",
    "gh-*-mode-only images follow the theme": (
        "(() => { const dark = document.documentElement.dataset.mpTheme === 'dark'; "
        "const shown = (alt) => getComputedStyle(q(`img[alt=\"${alt}\"]`)).display !== 'none'; "
        "return [shown('Dark mode only') === dark && shown('Light mode only') === !dark, document.documentElement.dataset.mpTheme] })()"
    ),
    "<picture> shows the source for the theme": (
        "(() => { const theme = document.documentElement.dataset.mpTheme; const img = q('picture img'); "
        "return [qa('picture source[data-mp-media]').length === 2 && img.complete && img.currentSrc.split('#')[0].endsWith(`file/${D}images/swatch-${theme}.png`), theme + ' ' + img.currentSrc] })()"
    ),
    "custom anchor keeps a prefixed name": "[q('a[name=\"user-content-my-custom-anchor-point\"]') !== null, '']",
    "line breaks": "[qa('p br').length >= 3, qa('p br').length]",
    "HTML comment hidden": "[!B.innerHTML.includes('This content will not appear'), '']",
    "backslash escapes": "[B.textContent.includes('*our-new-project*'), '']",
    "details opened by details_tags_open": "[qa('details').filter(d => !d.classList.contains('mp-video')).every(d => d.open), qa('details').length]",
    "nested lists and start number": "[q('ol[start=\"100\"] ul ul') !== null && q('ol ul ul') !== null, '']",
    "blockquote": "[qa('blockquote').some(b => b.textContent.includes('Text that is a quote')), '']",
    "<script> removed": "[!B.querySelector('script') && window.__mpInjected === undefined, String(window.__mpInjected)]",
    "event-handler attributes removed": "[qa('*').every(e => ![...e.attributes].some(a => a.name.startsWith('on'))), '']",
    "style= attribute removed": "[q('#user-content-styled-paragraph') !== null && !q('#user-content-styled-paragraph').hasAttribute('style'), q('#user-content-styled-paragraph')?.outerHTML]",
    "iframe, form, text input, button removed": "[!q('iframe') && !q('form') && !q('input:not([type=checkbox])') && !q('button'), '']",
    "user <svg> removed": "[qa('svg').every(s => s.closest('[data-mp-kind=mermaid], [data-mp-kind=math]')), qa('svg').filter(s => !s.closest('[data-mp-kind=mermaid], [data-mp-kind=math]')).length]",
    "colour models render no chip": "[!qa('code').some(c => c.children.length || c.querySelector('*') || /color|swatch|chip/i.test(c.className)), '']",
    "emoticons stay text": "[qa('p').some(p => p.textContent.includes('stay text :) :-( ;)')), '']",
    "relative links to non-media, non-Markdown files are disabled": (
        "(() => { const a = qa('a').find(a => a.textContent === 'the notes'); "
        "return [!!a && !a.hasAttribute('href') && a.title.startsWith(D + 'notes.txt') && a.hasAttribute('data-mp-unavailable') && "
        "getComputedStyle(a).cursor === 'not-allowed' && qa('a').some(a => a.textContent === 'A source file' && !a.hasAttribute('href')), a?.outerHTML] })()"
    ),
    "forged data-line values dropped": (
        "[q('#user-content-forged-lines') !== null && !q('#user-content-forged-lines').hasAttribute('data-line-start') && "
        "qa('[data-line-start]').every(e => Number(e.dataset.lineStart) < 400 && Number(e.dataset.lineEnd) < 400), '']"
    ),
    "forged data-mp-open dropped": "[q('#user-content-forged-open') !== null && !q('#user-content-forged-open').hasAttribute('data-mp-open'), q('#user-content-forged-open')?.outerHTML]",
    "forged data-mp-video dropped, no player": "[q('#user-content-forged-video') !== null && !q('#user-content-forged-video').hasAttribute('data-mp-video') && !q('video'), '']",
    "no authored data-mp-* attribute survives": (
        "(() => { const allowed = new Set(['data-mp-kind', 'data-mp-lang', 'data-mp-open', 'data-mp-media', 'data-mp-unavailable']); "
        "const bad = qa('[id^=user-content-forged], [id^=user-content-fake]').flatMap(e => [...e.attributes].filter(a => a.name.startsWith('data-mp-') || a.name.startsWith('data-line-')).map(a => e.id + '@' + a.name)); "
        "const unknown = qa('*').flatMap(e => [...e.attributes].filter(a => a.name.startsWith('data-mp-') && !allowed.has(a.name)).map(a => e.tagName + '@' + a.name)); "
        "return [bad.length === 0 && unknown.length === 0, bad.concat(unknown).slice(0, 5).join(', ')] })()"
    ),
    "forged highlight block not decorated": "[!q('#mp-body > div:not([data-line-start]) [class^=pl-]') && qa('div.highlight:not([data-mp-kind])').length === 1 && !qa('[data-mp-trust]').length, '']",
    "authored mp-status/mp-errors classes are not page chrome": (
        "[getComputedStyle(q('#user-content-fake-status')).position !== 'fixed' && "
        "getComputedStyle(q('#user-content-fake-errors')).borderStyle === 'none', getComputedStyle(q('#user-content-fake-status')).position]"
    ),
    "MathJax \\href yields no link": (
        "(() => { const p = qa('p').find(p => p.textContent.startsWith('Math commands that reach')); "
        "return [!!p && p.querySelectorAll('mjx-container').length === 4 && !p.querySelector('mjx-container a, mjx-container [href]'), p?.innerHTML.slice(0, 200)] })()"
    ),
    "MathJax \\style, \\cssId and \\class yield no style, id or class": (
        "(() => { const p = qa('p').find(p => p.textContent.startsWith('Math commands that reach')); "
        "return [!!p && p.querySelectorAll('mjx-container').length === 4 && ![...p.querySelectorAll('mjx-container *')].some(e => /position/.test(e.getAttribute('style') ?? '') || e.id === 'mp-status' || e.classList.contains('mp-status')), ''] })()"
    ),
    "MathJax \\style transform cannot cover the page": (
        "(() => { const p = qa('p').find(p => p.textContent.startsWith('A scaled formula')); const box = p?.querySelector('mjx-container')?.getBoundingClientRect(); "
        "return [!!box && box.width < 200 && box.height < 200, box ? Math.round(box.width) + 'x' + Math.round(box.height) : 'missing'] })()"
    ),
    "absorbed stamps grant no control attributes or decoration": (
        "(() => { const ids = ['absorb1', 'absorb2', 'leak1', 'absorb4b']; const out = []; "
        "for (const id of ids) { const el = document.getElementById('user-content-' + id); if (!el) continue; "
        "const ctl = [...el.attributes].filter(a => a.name.startsWith('data-mp-') || a.name.startsWith('data-line-')).map(a => a.name); "
        "if (ctl.length || el.querySelector('svg, mjx-container')) out.push(id + ': ' + ctl.join(' ') + (el.querySelector('svg, mjx-container') ? ' decorated' : '')); } "
        "const li = qa('li').find(li => li.textContent.includes('x_1 * y_2')); "
        "if (li && [...li.querySelectorAll('*')].concat(li).some(e => [...e.attributes].some(a => /^data-mp-(lang|media|unavailable|kind)$/.test(a.name)))) out.push('list item keeps forged data-mp-*'); "
        "return [out.length === 0 && ids.some(id => document.getElementById('user-content-' + id)), out.join('; ') || 'present: ' + ids.filter(id => document.getElementById('user-content-' + id)).join(',')] })()"
    ),
    "no attribute or text holds a stamp": (
        "(() => { const stamp = /[0-9a-f]{24}(:\\d+)?/; const attrs = [...document.querySelectorAll('*')].flatMap(e => [...e.attributes].filter(a => a.value.includes('data-mp-trust') || (a.name !== 'd' && stamp.test(a.value) && !/^(id|xlink:href|href|aria-labelledby|data-c)$/.test(a.name))).map(a => e.tagName + '@' + a.name + '=' + a.value.slice(0, 40))); "
        "const text = B.textContent.includes('data-mp-trust'); "
        "return [attrs.length === 0 && !text, attrs.slice(0, 4).join(' | ') + (text ? ' text' : '')] })()"
    ),
    "MathJax \\data cannot set control attributes": (
        "(() => { const p = qa('p').find(p => p.textContent.startsWith('Math data attributes')); "
        "const bad = p ? [...p.querySelectorAll('mjx-container *')].flatMap(e => [...e.attributes].filter(a => a.name.startsWith('data-mp-') || a.name.startsWith('data-line-')).map(a => a.name)) : ['missing']; "
        "return [!!p?.querySelector('mjx-container') && bad.length === 0 && !qa('mjx-container [data-mp-kind], mjx-container svg svg[aria-roledescription]').length, bad.join(' ')] })()"
    ),
    "encoded and backslash path escapes emit no URL": (
        "(() => { const out = []; "
        "for (const a of qa('a')) if (['Encoded escape', 'backslash escape'].includes(a.textContent) && a.hasAttribute('href')) out.push(a.textContent + ' href=' + a.getAttribute('href')); "
        "for (const alt of ['enc-img-short', 'enc-img', 'enc-srcset']) { const img = q(`img[alt=${alt}]`); if (!img) out.push(alt + ' missing'); else if (img.getAttribute('src') || img.getAttribute('srcset')) out.push(alt + ' src=' + (img.getAttribute('src') ?? img.getAttribute('srcset'))); } "
        "const urls = qa('[href], [src], [srcset]').flatMap(e => ['href', 'src', 'srcset'].map(n => e.getAttribute(n)).filter(Boolean)).filter(u => !/^[a-z][a-z+.-]*:|^#|^\\/\\//i.test(u)); "
        "for (const u of urls) if (!u.startsWith('file/') || /(^|\\/)\\.\\.?(\\/|$)|%2f|%5c|\\\\/i.test(u)) out.push('bad relative URL ' + u); "
        "const stream = new URL('events', location.href).pathname; "
        "const events = performance.getEntriesByType('resource').filter(r => r.initiatorType === 'img' && new URL(r.name).pathname === stream); "
        "if (events.length) out.push('image request to events'); "
        "return [out.length === 0, out.join('; ')] })()"
    ),
    "no attribute carries the page origin or token": (
        "(() => { const token = location.pathname.split('/')[1]; const needles = [location.origin, location.host]; "
        "if (/^[0-9a-f]{32}$/.test(token)) needles.push(token); "
        "const hits = [...document.querySelectorAll('*')].flatMap(e => [...e.attributes].filter(a => needles.some(n => a.value.includes(n))).map(a => e.tagName + '@' + a.name)); "
        "return [hits.length === 0, hits.slice(0, 5).join(', ')] })()"
    ),
    "javascript: URL never becomes a link": "[!qa('a').some(a => /^\\s*javascript:/i.test(a.getAttribute('href') ?? '')) && B.textContent.includes('A javascript: link'), '']",
}


# Run after CHECKS against the harness, which exposes the Preview as window.__mp.
# They edit the document and check, synchronously after the re-render, that the
# DOM morph kept already highlighted, typeset and drawn blocks instead of
# reverting them to source text.
RERENDER_CHECKS: dict[str, str] = {
    "one-character edit keeps rendered blocks": (
        "(() => { const P = window.__mp.preview; const before = qa('[data-mp-kind]'); "
        "const lines = P.source.split('\\n'); lines[3] += ' x'; P.setDocument(P.path, lines); "
        "const kept = before.filter(e => e.isConnected).length; "
        "const rendered = qa('div.highlight[data-mp-lang=ruby] pre span[class^=pl-]').length > 0 && "
        "qa('[data-mp-kind=math]').every(m => m.querySelector('mjx-container')) && q('[data-mp-kind=mermaid] svg') !== null; "
        "return [kept === before.length && rendered && B.textContent.includes('in a repository. The browser check script asserts on the rendered DOM of this file. x'), kept + '/' + before.length] })()"
    ),
    "inserted line shifts data-line-start of kept blocks": (
        "(() => { const P = window.__mp.preview; const block = q('div.highlight[data-mp-lang=ruby]'); "
        "const start = Number(block.dataset.lineStart); P.setDocument(P.path, ['', ...P.source.split('\\n')]); "
        "return [block.isConnected && Number(block.dataset.lineStart) === start + 1 && block.querySelector('span[class^=pl-]') !== null, "
        "start + ' -> ' + block.dataset.lineStart] })()"
    ),
    "out-of-range data-line-start does not slow or grow the line table": (
        "(() => { const P = window.__mp.preview; const lines = P.source.split('\\n').length; "
        "const el = document.createElement('p'); el.setAttribute('data-line-start', '200000000'); el.setAttribute('data-line-end', '200000000'); el.textContent = 'raw'; "
        "B.append(el); const t0 = performance.now(); P.sync.rebuild(lines); const ms = performance.now() - t0; "
        "P.sync.setCursor(lines + 50); const band = parseFloat(document.getElementById('mp-cursor').style.top); el.remove(); P.sync.rebuild(lines); P.sync.setCursor(null); "
        "return [ms < 50 && Number.isFinite(band) && band < B.getBoundingClientRect().bottom + scrollY, Math.round(ms * 10) / 10 + ' ms, band ' + band] })()"
    ),
    "theme config switches stylesheets, attributes and mermaid": (
        "(async () => { const P = window.__mp.preview; const html = document.documentElement; "
        "const settle = async () => { for (let i = 0; i < 200; i++) { await new Promise(r => setTimeout(r, 25)); "
        "const svg = q('[data-mp-kind=mermaid] svg'); if (svg && !q('[data-mp-kind=mermaid]:not(:has(svg))')) return svg.outerHTML; } return ''; }; "
        "const css = () => document.getElementById('mp-markdown-css').getAttribute('href').split('/').pop(); "
        "const seen = []; const lightSvg = q('[data-mp-kind=mermaid] svg').outerHTML; "
        "P.setConfig({ theme: { name: 'dark', high_contrast: false } }); const darkSvg = await settle(); "
        "seen.push([html.dataset.mpTheme, html.dataset.mpContrast, css(), !!darkSvg && darkSvg !== lightSvg]); "
        "P.setConfig({ theme: { name: 'dark', high_contrast: true } }); await settle(); "
        "seen.push([html.dataset.mpTheme, html.dataset.mpContrast, css()]); "
        "P.setConfig({ theme: { name: 'light', high_contrast: true } }); const hcSvg = await settle(); "
        "seen.push([html.dataset.mpTheme, html.dataset.mpContrast, css(), !!document.getElementById('mp-primer-hc'), B.dataset.lightTheme, !!hcSvg]); "
        "P.setConfig({ theme: { name: 'light', high_contrast: false } }); await settle(); "
        "seen.push([html.dataset.mpTheme, css(), B.dataset.lightTheme === undefined]); "
        "const want = JSON.stringify([['dark','normal','github-markdown-dark.css',true],['dark','high','github-markdown-dark-high-contrast.css'],"
        "['light','high','github-markdown-light.css',true,'light_high_contrast',true],['light','github-markdown-light.css',true]]); "
        "return [JSON.stringify(seen) === want && !q('.mp-mermaid-error'), JSON.stringify(seen)] })()"
    ),
    "cursor_line config shows, colours and hides the band": (
        "(() => { const P = window.__mp.preview; const band = document.getElementById('mp-cursor'); "
        "P.setConfig({ cursor_line: { disable: false, color: '#123456', opacity: 0.5 }, scroll: { disable: true } }); P.setCursor(5); "
        "const shown = getComputedStyle(band).display === 'block' && getComputedStyle(band).backgroundColor === 'rgb(18, 52, 86)' && band.style.opacity === '0.5'; "
        "P.setConfig({ cursor_line: { disable: true }, scroll: { disable: true } }); const hidden = getComputedStyle(band).display === 'none'; "
        "P.setConfig({ theme: { name: 'light' } }); P.setCursor(null); "
        "return [shown && hidden, 'shown ' + shown + ', hidden ' + hidden] })()"
    ),
    "clicking a forged data-mp-open link does not call api/open": (
        "(() => { const opened = window.__mp.opened; opened.length = 0; "
        "const stop = (e) => e.preventDefault(); document.addEventListener('click', stop); "
        "const click = (el) => el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 })); "
        "click(q('#user-content-forged-open')); const forged = opened.length; "
        "click(qa('a').find(a => a.textContent === 'Another Markdown file')); "
        "document.removeEventListener('click', stop); "
        "return [forged === 0 && opened.join() === 'other.md', 'forged: ' + forged + ', real: ' + opened.join()] })()"
    ),
    "changed code block is highlighted again": (
        "(async () => { const P = window.__mp.preview; const lines = P.source.split('\\n'); "
        "const at = lines.indexOf('puts markdown.to_html'); lines[at] = 'puts markdown.to_html(1)'; P.setDocument(P.path, lines); "
        "const before = q('div.highlight[data-mp-lang=ruby]'); const plain = before.querySelector('span') === null; "
        "for (let i = 0; i < 100 && document.documentElement.dataset.mpRender !== 'complete'; i++) await new Promise(r => setTimeout(r, 50)); "
        "const after = q('div.highlight[data-mp-lang=ruby]'); "
        "return [plain && after.textContent.includes('to_html(1)') && after.querySelector('span[class^=pl-]') !== null, 'plain after morph: ' + plain] })()"
    ),
}

# Run instead of RERENDER_CHECKS when the page is served by the preview server.
# They use the real event stream and api/open, so they run last.
SERVER_CHECKS: dict[str, str] = {
    "api/open error is shown without leaving the page": (
        "(async () => { const link = qa('a').find(a => a.textContent === 'a missing Markdown file'); "
        "link.click(); const box = document.getElementById('mp-errors'); "
        "for (let i = 0; i < 100 && box.hidden; i++) await new Promise(r => setTimeout(r, 50)); "
        "return [!box.hidden && box.textContent.includes('missing.md') && B.textContent.includes('GitHub Markdown feature fixture'), box.textContent] })()"
    ),
    "relative Markdown links switch the preview and back": (
        "(async () => { const link = qa('a').find(a => a.textContent === 'Another Markdown file'); link.click(); "
        "for (let i = 0; i < 100 && !q('h1')?.textContent.includes('Another Markdown file'); i++) await new Promise(r => setTimeout(r, 50)); "
        "const switched = q('h1')?.textContent.includes('Another Markdown file') && document.title.startsWith('other.md'); "
        "qa('a').find(a => a.textContent === 'the feature fixture')?.click(); "
        "for (let i = 0; i < 100 && !q('h1')?.textContent.includes('GitHub Markdown feature fixture'); i++) await new Promise(r => setTimeout(r, 50)); "
        "return [switched && q('h1')?.textContent.includes('GitHub Markdown feature fixture'), document.title] })()"
    ),
}


def checks_script(checks: dict[str, str], doc_dir: str) -> str:
    """Build one expression that runs every check in the page and returns name -> [ok, detail].

    The checks are spliced in as function literals: the page CSP forbids eval, and
    only the top-level expression sent over the protocol is exempt from it.
    """

    entries = ",".join(
        f"[{orjson.dumps(name).decode()}, () => ({expr})]" for name, expr in checks.items()
    )
    return (
        f"(async () => {{ const D = {orjson.dumps(doc_dir).decode()}; const B = document.getElementById('mp-body'); "
        "const q = (s) => B.querySelector(s); const qa = (s) => [...B.querySelectorAll(s)]; "
        f"const out = {{}}; for (const [name, fn] of [{entries}]) {{ "
        "try { out[name] = await fn(); } catch (e) { out[name] = [false, 'threw: ' + e]; } } "
        "return out; })()"
    )


def nvim_lua(server: str, code: str) -> None:
    """Run Lua in the nvim that hosts the preview server, through its --listen socket."""
    # luaeval takes an expression, so the statements run inside a function literal.
    expr = f"luaeval({orjson.dumps(f'(function() {code} return 1 end)()').decode()})"
    subprocess.run(["nvim", "--server", server, "--remote-expr", expr], check=True, capture_output=True, timeout=10)


# Each step changes the editor-side config through the plugin's Lua API, which
# broadcasts update_config over the event stream, then waits for the page to
# reflect it. The theme has no public setter; it is set on config.options and
# broadcast by the next public toggle.
SSE_CONFIG_STEPS: list[tuple[str, str, str]] = [
    (
        "update_config over SSE: details_tags_off closes <details>",
        'require("markdown-preview").details_tags_off()',
        "[...document.querySelectorAll('#mp-body details:not(.mp-video)')].every(d => !d.open)",
    ),
    (
        "update_config over SSE: dark high-contrast theme applied",
        'local c = require("markdown-preview.config").options; c.theme.name = "dark"; c.theme.high_contrast = true; '
        'require("markdown-preview").details_tags_on()',
        "document.documentElement.dataset.mpTheme === 'dark' && document.documentElement.dataset.mpContrast === 'high' && "
        "document.getElementById('mp-markdown-css').getAttribute('href').endsWith('github-markdown-dark-high-contrast.css') && "
        "[...document.querySelectorAll('#mp-body details:not(.mp-video)')].every(d => d.open) && "
        "document.querySelector('[data-mp-kind=mermaid] svg') !== null",
    ),
    (
        "update_config over SSE: light theme applied",
        'local c = require("markdown-preview.config").options; c.theme.name = "light"; c.theme.high_contrast = false; '
        'require("markdown-preview").scroll_on()',
        "document.documentElement.dataset.mpTheme === 'light' && "
        "document.getElementById('mp-markdown-css').getAttribute('href').endsWith('github-markdown-light.css')",
    ),
    (
        "update_config over SSE: cursorline_off hides the band",
        'require("markdown-preview").cursorline_off()',
        "getComputedStyle(document.getElementById('mp-cursor')).display === 'none'",
    ),
    (
        "update_config over SSE: cursorline_on shows the band again",
        'local c = require("markdown-preview.config").options; c.theme.name = "system"; '
        'require("markdown-preview").cursorline_on()',
        "getComputedStyle(document.getElementById('mp-cursor')).display === 'block'",
    ),
]


async def run_sse_config_steps(page: Any, server: str) -> dict[str, list]:
    """Drive SSE_CONFIG_STEPS against the running nvim and the open page."""
    results: dict[str, list] = {}
    for name, lua, done in SSE_CONFIG_STEPS:
        try:
            nvim_lua(server, lua)
            await page.wait_for(f"({done})", 15)
            results[name] = [True, ""]
        except (subprocess.SubprocessError, TimeoutError) as err:
            results[name] = [False, str(err)[:200]]
    return results


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        logger.debug(format, *args)


def serve_repo() -> tuple[ThreadingHTTPServer, int]:
    """Serve the repository root on a free loopback port in a daemon thread."""
    handler = functools.partial(QuietHandler, directory=str(REPO))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


async def run_checks(url: str, timeout: float, width: int, doc_dir: str, nvim: str | None) -> int:
    """Open `url`, wait for the full render, run CHECKS and report; return the exit code."""
    async with Chrome(width=width, mobile=width < 768) as chrome:
        page = await chrome.open(url)
        failures: list[str] = []
        try:
            await page.wait_for("document.documentElement.dataset.mpRender === 'complete'", timeout)
        except TimeoutError as err:
            state = await page.eval("document.documentElement.dataset.mpRender")
            failures.append(f"render did not complete: {err} (state: {state})")
        results = await page.eval(checks_script(CHECKS, doc_dir))
        if await page.eval("window.__mp !== undefined"):
            results |= await page.eval(checks_script(RERENDER_CHECKS, doc_dir))
        else:
            if nvim:
                results |= await run_sse_config_steps(page, nvim)
            results |= await page.eval(checks_script(SERVER_CHECKS, doc_dir))
        for name, (ok, detail) in results.items():
            mark = "ok  " if ok else "FAIL"
            print(f"{mark} {name}" + ("" if ok else f"  [{detail}]"))
            if not ok:
                failures.append(name)
        stats = await page.eval("window.__mp?.preview.stats ?? null")
        print(f"render stats: {stats}")
        csp = await page.csp_violations()
        errors = await page.eval("window.__mp?.errors ?? []")
        # api/open answering 404 for the missing-file link is the expected result
        # of a server check, not a page error.
        network = [
            m
            for m in page.console
            if ("Failed to load resource" in m or "[security]" in m) and "/api/open)" not in m
        ]
        for label, items in (
            ("CSP violation", csp),
            ("page exception", page.exceptions),
            ("library error", errors),
            ("console error", network),
        ):
            for item in items:
                print(f"FAIL {label}: {item}")
                failures.append(f"{label}: {item}")
        overflow = await page.eval(
            "document.documentElement.scrollWidth - document.documentElement.clientWidth"
        )
        # Elements reaching past the viewport that are not inside their own
        # scrolling or clipping box, i.e. the ones that would scroll the page.
        offenders = await page.eval(
            "(() => { const W = document.documentElement.clientWidth; "
            "const clipped = (e) => { for (let p = e.parentElement; p && p !== document.body; p = p.parentElement) "
            "{ if (/auto|scroll|hidden|clip/.test(getComputedStyle(p).overflowX)) return true; } return false; }; "
            "return [...document.body.querySelectorAll('*')].filter(e => e.getBoundingClientRect().right > W + 0.5 && !clipped(e))"
            ".slice(0, 8).map(e => e.tagName + '.' + e.className + ' ' + Math.round(e.getBoundingClientRect().right)); })()"
        )
        if overflow > 0 or offenders:
            print(f"FAIL horizontal page overflow at {width}px: {overflow}px; {offenders}")
            failures.append("horizontal overflow")
        else:
            print(f"ok   no horizontal page overflow at {width}px")
    print(f"\n{len(results) - sum(1 for _, (ok, _) in results.items() if not ok)}/{len(results)} DOM checks passed")
    if failures:
        print(f"{len(failures)} failure(s):", *failures, sep="\n  ")
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="page to check instead of the local harness")
    parser.add_argument("--timeout", type=float, default=60.0, help="seconds to wait for the render")
    parser.add_argument("--width", type=int, default=1280, help="viewport width in CSS px")
    parser.add_argument(
        "--doc-dir",
        help="directory of the fixture relative to the preview root, with a trailing slash "
        "(default: '' for the harness, 'tests/fixtures/' with --url)",
    )
    parser.add_argument(
        "--nvim",
        metavar="SOCKET",
        help="--listen address of the nvim running the preview server; with --url, also checks "
        "update_config over the event stream by driving the plugin's Lua API",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING)
    server = None
    url = args.url
    if url is None:
        server, port = serve_repo()
        url = f"http://127.0.0.1:{port}/tests/browser/render/index.html?fixture=github-features.md&theme=light"
    try:
        doc_dir = args.doc_dir if args.doc_dir is not None else ("" if args.url is None else "tests/fixtures/")
        return asyncio.run(run_checks(url, args.timeout, args.width, doc_dir, args.nvim))
    finally:
        if server:
            server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
