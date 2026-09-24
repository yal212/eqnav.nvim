#!/usr/bin/env node
//
// mathjax-daemon.mjs — the rendering backend for eqnav.nvim.
//
// Loads MathJax once (~1s) and then answers render requests in ~10-30ms, so
// building an index of a few hundred equations costs one startup instead of
// a few hundred. Speaks newline-delimited JSON on stdin/stdout:
//
//   ->  {"id":7,"equation":"\\frac a b","display":true,"color":"e0def4","preamble":"..."}
//   <-  {"id":7,"ok":true,"svg":"<svg ...>","width":9.7,"height":4.5,"depth":2.0}
//   <-  {"id":7,"ok":false,"err":"Undefined control sequence \\fra"}
//
// Requests carry ids and are answered as they complete, so the Lua side can
// pipeline a whole document in one batch.
//
// Other modes, both used by the plugin and by the test suite:
//   --in FILE --out FILE.svg [--display] [--color HEX] [--width EX]   one-shot, no daemon
//   --list-paths                                                      resolution probe for :checkhealth
//
// NOTE ON SERIALIZATION -- this is load-bearing, do not "simplify" it.
// MathJax 4 stamps every node with a data-latex attribute holding its raw TeX
// source, so `a < b` yields literally data-latex="<". Serializing with
// adaptor.innerHTML/outerHTML leaves <, > and & unescaped: legal HTML, illegal
// XML. rsvg-convert parses strictly and rejects the file outright. We must use
// adaptor.serializeXML. tests/daemon_xml_spec.mjs guards this.
//
import { argv, exit, stderr, stdin, stdout } from "node:process";
import { promises as fs } from "node:fs";
import { createInterface } from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// TeX packages loaded up front. Anything not built into `input/tex` also needs a
// matching "[tex]/<name>" entry in the loader list below -- listing it here alone
// gets you a "Package not found. Omitted." warning and silently missing macros.
// `autoload` + `require` pull in the long tail on demand, so this list only needs
// to cover what documents use without asking (\begin{align}, \newcommand).
// `color` is kept for equations that colour themselves with \color / \textcolor;
// eqnav's own theme matching no longer goes through TeX at all -- see colorize().
const BUILTIN_PACKAGES = ["base", "ams", "newcommand", "configmacros", "noundefined", "autoload", "require", "textmacros"];
const EXTENSION_PACKAGES = [
  "color", "noerrors", "boldsymbol", "braket", "cancel", "mathtools",
  "physics", "empheq", "cases", "enclose", "unicode", "amscd", "bbox",
];
const PACKAGES = [...BUILTIN_PACKAGES, ...EXTENSION_PACKAGES];

// LaTeX defines each of these in latex.ltx guarded by \ifmmode, so all of them
// are legal in math mode and pdflatex renders them. MathJax ships no definition
// for any but \S, so `noundefined` drew the macro's own name in red instead --
// and `textmacros` does not cover them either, not even inside \text{}. Mapping
// them to the glyph LaTeX would have produced is the whole fix; the code points
// are the ones latex.ltx names (\mathparagraph, \mathsterling, ...).
const MACROS = {
  dag: "\\dagger",
  ddag: "\\ddagger",
  P: "\\unicode{x00B6}",           // PILCROW SIGN
  mathparagraph: "\\unicode{x00B6}",
  mathsection: "\\unicode{x00A7}", // SECTION SIGN; \S already works
  pounds: "\\unicode{x00A3}",      // POUND SIGN
  mathsterling: "\\unicode{x00A3}",
  copyright: "\\unicode{x00A9}",   // COPYRIGHT SIGN
  mathdollar: "\\unicode{x0024}",
};

function parseArgs(a) {
  const o = { display: false, color: null, ex: 8, width: null, daemon: false, listPaths: false };
  for (let i = 2; i < a.length; i++) {
    const k = a[i];
    if (k === "--in") o.input = a[++i];
    else if (k === "--out") o.output = a[++i];
    else if (k === "--display") o.display = true;
    else if (k === "--color") o.color = a[++i];
    else if (k === "--ex") o.ex = parseFloat(a[++i]);
    else if (k === "--width") o.width = parseFloat(a[++i]);
    else if (k === "--daemon") o.daemon = true;
    else if (k === "--list-paths") o.listPaths = true;
  }
  return o;
}

// Where @mathjax/src might live. health.lua invokes --list-paths rather than
// reimplementing this, so the resolution order exists in exactly one place.
function candidatePaths() {
  const seen = new Set();
  const out = [];
  const add = (p) => { if (p && !seen.has(p)) { seen.add(p); out.push(p); } };
  add(process.env.EQNAV_MATHJAX_PATH);
  add(path.join(HERE, "..", "node_modules", "@mathjax", "src"));
  add(path.join(process.cwd(), "node_modules", "@mathjax", "src"));
  return out;
}

async function resolveMathJax() {
  for (const p of candidatePaths()) {
    try {
      await fs.access(path.join(p, "package.json"));
      return p;
    } catch { /* keep looking */ }
  }
  return null;
}

let MathJax = null;

async function boot() {
  const root = await resolveMathJax();
  if (!root) {
    throw new Error(
      "@mathjax/src not found. Run `npm install` in the eqnav.nvim plugin directory, " +
      "or set $EQNAV_MATHJAX_PATH. Searched: " + candidatePaths().join(", ")
    );
  }
  const { createRequire } = await import("node:module");
  const req = createRequire(path.join(root, "package.json"));
  const source = req.resolve("@mathjax/src/source");
  const mod = req(source);
  MathJax = await mod.init({
    loader: {
      load: [
        "input/tex", "output/svg", "adaptors/liteDOM",
        ...EXTENSION_PACKAGES.map((p) => `[tex]/${p}`),
      ],
    },
    tex: { packages: PACKAGES, macros: MACROS },
    // 'local' inlines the glyph <defs> into each SVG, which is what we need for
    // standalone files -- both rsvg-convert and the HTML export get a self
    // contained document with no shared cache to resolve.
    //
    // Inline breaks off. By default MathJax cuts inline math into one <svg> per
    // place a line could break there, for a browser to wrap -- and render()
    // keeps node.children[0], so `a+b+c` came back as a lone `a` (#46). Whether
    // display math is broken to fit is decided per render; see render().
    svg: { fontCache: "local", linebreaks: { inline: false } },
    startup: { typeset: false },
  });
  return MathJax;
}

// Feed a preamble to MathJax one line at a time, swallowing per-line failures.
// A real .tex preamble is full of \RequirePackage / \makeatletter that MathJax
// cannot execute; those must not take the document's \newcommand definitions
// down with them. (Same approach Overleaf takes.)
let lastPreamble = null;
async function applyPreamble(preamble) {
  if (!preamble || preamble === lastPreamble) return;
  lastPreamble = preamble;
  for (const line of preamble.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("%")) continue;
    try { await MathJax.tex2svgPromise(t, { display: false }); } catch { /* expected, skip */ }
  }
}

// The px per ex MathJax lays out in. It only shows where MathJax writes px of
// its own, which is inside a labelled table (see stampPixelSize); passed on
// every render so that is a known number rather than MathJax's default.
const MJ_EX = 8;

function exNum(v) {
  const m = /^([\d.eE+-]+)ex$/.exec(String(v || "").trim());
  return m ? parseFloat(m[1]) : null;
}

// Convert MathJax's ex-relative dimensions to absolute px so rasterization is
// deterministic instead of depending on the renderer's default DPI.
//
// An equation with a \tag is a labelled table, and MathJax sizes those to their
// container: width="100%", the natural width moved to a min-width style, and no
// viewBox. Inside, the table and its labels are each a nested <svg> with a
// 1-unit-wide viewBox, placed by preserveAspectRatio against that 100%. With no
// container, rsvg-convert drew a 14x1 PNG (#40). Copying MathJax's
// data-mjx-viewBox back to viewBox is not enough: the nested layout is in MathJax
// px, not viewBox units, and comes out clipped, down to one row of an align.
// What it needs is a real viewport of the natural width, in MathJax px, and
// that is what the viewBox here gives it. The tag lands at the right of it.
function stampPixelSize(adaptor, svg, exPx) {
  let w = exNum(adaptor.getAttribute(svg, "width"));
  const h = exNum(adaptor.getAttribute(svg, "height"));
  const style = adaptor.getAttribute(svg, "style") || "";
  const dm = /vertical-align:\s*([-\d.]+)ex/.exec(style);
  const depth = dm ? parseFloat(dm[1]) : 0;
  const mw = /min-width:\s*([\d.]+)ex;?\s*/.exec(style);
  if (w === null && h !== null && mw && /%$/.test(adaptor.getAttribute(svg, "width") || "")) {
    w = parseFloat(mw[1]);
    adaptor.setAttribute(svg, "viewBox", `0 0 ${(w * MJ_EX).toFixed(3)} ${(h * MJ_EX).toFixed(3)}`);
    adaptor.setAttribute(svg, "style", style.replace(mw[0], "").trim());
  }
  if (w !== null) adaptor.setAttribute(svg, "width", (w * exPx).toFixed(2) + "px");
  if (h !== null) adaptor.setAttribute(svg, "height", (h * exPx).toFixed(2) + "px");
  return { width: w, height: h, depth };
}

// Colour by resolving the currentColor attributes MathJax draws every glyph
// with. Two ways not to do this, both of which were tried:
//
//   \color{#hex}{equation} -- wrapping the source in a TeX group. An environment
//   cannot legally sit inside a group, so MathJax answers every \begin{align},
//   \begin{equation}, \begin{gather}, ... with an "Erroneous nesting of equation
//   structures" error box. Since a colour is always passed, that was every
//   environment in every document.
//
//   style="color: #hex" on the root <svg>, leaving the glyphs as currentColor.
//   librsvg resolves it, but ImageMagick -- raster.lua's fallback when librsvg is
//   absent -- resolves it to nothing and rasterizes a completely blank PNG.
//
// Rewriting the attributes keeps the user's TeX untouched and is understood by
// both rasterizers. export/html.lua reverses it to hand colour back to CSS.
function colorize(xml, color) {
  if (!color) return xml;
  const hex = "#" + String(color).replace(/^#/, "");
  return xml.replace(/(fill|stroke)="currentColor"/g, `$1="${hex}"`);
}

// Give a parse error's box and text colours of their own. MathJax draws an
// <merror> as a background rect and the source as <text>, both unfilled, and
// leaves their colours to its stylesheet -- which a browser has and a
// standalone rasterizer does not. Without one both inherit the root fill that
// colorize() sets to the foreground, and `\frac{a}` came out as a solid block
// with nothing readable in it (#62).
//
// Red, as `noundefined` draws an unknown macro, on a translucent red box that
// reads on dark and light schemes alike. Named, not hex: export/html.lua hands
// every #rrggbb back to CSS, and an error should stay red in the page too.
// Only an merror's own rect -- \colorbox and bbox draw data-background rects
// with colours the author chose.
function markErrors(adaptor, node) {
  if (adaptor.kind(node) === "#text") return;
  if (adaptor.getAttribute(node, "data-mml-node") === "merror") {
    adaptor.setAttribute(node, "fill", "red");
    adaptor.setAttribute(node, "stroke", "red");
    for (const child of adaptor.childNodes(node)) {
      if (adaptor.kind(child) === "rect" && adaptor.getAttribute(child, "data-background")) {
        adaptor.setAttribute(child, "fill-opacity", "0.2");
      }
    }
  }
  for (const child of adaptor.childNodes(node)) markErrors(adaptor, child);
}

// tex2svgPromise, not tex2svg: @mathjax/mathjax-newcm-font fetches most of its
// glyph ranges on demand (double-struck, fraktur, calligraphic, monospace,
// sans-serif, ...) and \require{..} loads a package mid-render. Both raise
// MathJax's Retry signal, which only the promise API resolves -- the synchronous
// call simply throws, so \mathbb{R} never rendered at all.
//
// `width` is the room there is, in ex: display math wider than that is broken
// over several lines to fit (#41). Without one nothing is broken, which is what
// the HTML export wants -- a browser page has room -- and the picker gets.
async function render(equation, { display = false, color = null, preamble = null, ex = 8, width = null } = {}) {
  await applyPreamble(preamble);
  // One MathJax session serves every request, and its \label registry would
  // otherwise last as long: the second render of a labelled equation, from `r`
  // in the index or another document with the same label, came back as a
  // "Label multiply defined" error box (#15). texReset clears labels and tag
  // numbering only; the \newcommands applyPreamble installed survive it.
  MathJax.texReset();
  // Not an enormous container in place of no width: multline is set as wide as
  // its container, and came out wider than rsvg-convert will draw.
  const metrics = { display, ex: MJ_EX, em: 2 * MJ_EX };
  if (width > 0) metrics.containerWidth = width * MJ_EX;
  MathJax.startup.output.options.displayOverflow = width > 0 ? "linebreak" : "overflow";
  const node = await MathJax.tex2svgPromise(equation, metrics);
  const adaptor = MathJax.startup.adaptor;
  const svg = node.children[0];
  const dims = stampPixelSize(adaptor, svg, ex);
  markErrors(adaptor, svg);
  return { svg: colorize(adaptor.serializeXML(svg), color), ...dims };
}

async function main() {
  const o = parseArgs(argv);

  if (o.listPaths) {
    const root = await resolveMathJax();
    stdout.write(JSON.stringify({ candidates: candidatePaths(), resolved: root }) + "\n");
    return;
  }

  await boot();

  if (o.input) {
    const eq = await fs.readFile(o.input, "utf8");
    const r = await render(eq, { display: o.display, color: o.color, ex: o.ex, width: o.width });
    if (o.output) await fs.writeFile(o.output, r.svg, "utf8");
    else stdout.write(r.svg);
    return;
  }

  // Daemon mode. One JSON object per line in, one per line out.
  const rl = createInterface({ input: stdin, crlfDelay: Infinity });
  stdout.write(JSON.stringify({ ok: true, ready: true }) + "\n");
  for await (const line of rl) {
    if (!line.trim()) continue;
    let req;
    try {
      req = JSON.parse(line);
    } catch (e) {
      stdout.write(JSON.stringify({ ok: false, err: "bad JSON: " + e.message }) + "\n");
      continue;
    }
    try {
      const r = await render(req.equation, {
        display: !!req.display,
        color: req.color,
        preamble: req.preamble,
        ex: req.ex || 8,
        width: req.width,
      });
      stdout.write(JSON.stringify({ id: req.id, ok: true, ...r }) + "\n");
    } catch (e) {
      stdout.write(JSON.stringify({ id: req.id, ok: false, err: String(e.message || e) }) + "\n");
    }
  }
}

main().catch((e) => { stderr.write(String(e.stack || e) + "\n"); exit(1); });
