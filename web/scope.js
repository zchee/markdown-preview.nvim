// Library output (MathJax SVG, mermaid SVG and its labels) can carry attributes
// chosen by the document author, e.g. through TeX's \data. Elements inside
// such output are never treated as blocks to decorate.
const LIBRARY_OUTPUT = '[data-mp-kind], svg, mjx-container';

export function ownBlocks(root, selector) {
  return [...root.querySelectorAll(selector)].filter((el) => !el.parentElement?.closest(LIBRARY_OUTPUT));
}
