// Regression spec for the daemon's SVG serialization. Runs under plain node --
// no Neovim -- so it can guard the landmine cheaply in CI.
//
// MathJax 4 stamps every output node with a `data-latex` attribute holding its
// raw TeX source, so `a < b` produces literally data-latex="<". Serializing with
// adaptor.innerHTML/outerHTML leaves those <, > and & unescaped: valid HTML,
// invalid XML. rsvg-convert parses strictly and rejects the file with
// "Unescaped '<' not allowed in attributes values". The daemon must use
// adaptor.serializeXML.
//
// It also guards how the daemon colours an equation. Colouring through TeX --
// wrapping the source in \color{..}{..} -- is illegal around an environment and
// MathJax answers with an error box, and colouring by style on the root <svg>
// leaves glyphs as currentColor, which ImageMagick (raster.lua's fallback when
// librsvg is absent) rasterizes as a blank image. The daemon must resolve the
// currentColor attributes themselves.
//
// A \tag makes MathJax size the SVG as a percentage of its container (#40),
// which rsvg-convert, with no container, drew as a blank 14x1 PNG. And the
// daemon is one long MathJax session, so a \label it had already seen came
// back as a "multiply defined" error box on the next render of it (#15).
//
//   node tests/daemon_xml_spec.mjs
//
import { execFile, spawn, spawnSync } from "node:child_process";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const daemon = path.join(here, "..", "scripts", "mathjax-daemon.mjs");

// Equations whose TeX contains <, > or & -- the cases an HTML serializer breaks.
const TRIGGERS = ["a < b", "\\text{if } x < y", "\\xrightarrow{a<b} c", "\\overset{<}{=}", "p \\& q"];
// Ordinary equations that must keep working.
const CONTROLS = ["\\frac{a}{b}", "E=mc^2", "\\sum_{i=0}^{n} i^2", "\\begin{align} x &= 1 \\end{align}"];
// Rendered with --color, which is what eqnav itself always passes. The
// environments are the cases a TeX-level colour wrapper breaks; E=mc^2 is the
// control that works either way, which is why this went unnoticed.
const COLOR_CASES = [
  "\\begin{equation} x = 1 \\end{equation}",
  "\\begin{align} a &= b \\\\ c &= d \\end{align}",
  "\\begin{gather} p = q \\\\ r = s \\end{gather}",
  "\\begin{multline} a + b \\\\ + c \\end{multline}",
  "\\begin{eqnarray} \\alpha & = & \\beta \\end{eqnarray}",
  "E = mc^2",
];
const COLOR = "e0def4";

// LaTeX defines all of these in latex.ltx guarded by \ifmmode, so pdflatex
// renders them in math mode. MathJax ships a definition only for \S, so before
// the daemon declared them every one came back as its own name in red -- the
// `noundefined` package's output, which is neither an merror nor a failed
// render, so nothing upstream could notice. tests/fixtures/all-symbols.md's
// symbol row is where it showed up.
const MACRO_CASES = [
  "\\dag", "\\ddag", "\\P", "\\S", "\\pounds", "\\copyright",
  "\\mathsection", "\\mathparagraph", "\\mathsterling", "\\mathdollar",
];

// \tag puts the equation in a labelled table, which MathJax lays out as a
// percentage of its container: width="100%", no viewBox. The first is
// tests/fixtures/all-symbols.md's; the align has two rows and a tag on each,
// which is what a naive viewBox fix clips away.
const TAG_CASES = [
  "\\boxed{a^2 + b^2 = c^2} \\qquad \\operatorname{Aut}(G) \\qquad \\text{tagged:} \\quad x = y \\tag{$\\ast$}",
  "x = y \\tag{$\\ast$}",
  "\\begin{align} a &= b \\tag{7} \\\\ c &= \\frac{d}{e} \\tag{8} \\end{align}",
];

// Both fixtures carry this label, so opening one index and then the other sends
// it down one daemon twice, as does `r` in the index (#15).
const LABELLED = "\\begin{equation}\n  E = mc^2 \\label{eq:mass-energy}\n\\end{equation}";

const hasRsvg = spawnSync("rsvg-convert", ["--version"], { stdio: "ignore" }).status === 0;

// Return an offending attribute value if any attribute holds a raw < or >, or an
// & that does not start a recognized entity. null when clean.
function badAttribute(svg) {
  const attrRe = /=\s*"([^"]*)"/g;
  let m;
  while ((m = attrRe.exec(svg)) !== null) {
    const val = m[1];
    if (val.includes("<") || val.includes(">")) return val;
    if (/&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/.test(val)) return val;
  }
  return null;
}

// What `noundefined` produces for a macro MathJax does not know: the macro's own
// name as red mtext. Distinct from an merror box, and invisible to any check
// that only looks for one.
function undefinedMacro(svg) {
  const m = /data-mml-node="mtext" fill="red"[^>]*data-latex="([^"]*)"/.exec(svg);
  return m ? m[1] : null;
}

// MathJax bakes a failure into the image as a <merror> box, so a render that
// "succeeded" can still be a picture of an error message. This is the assertion
// render_spec.lua was missing -- "a non-empty PNG appeared" is satisfied by one.
function errorBox(svg) {
  const m = /data-mjx-error="([^"]*)"/.exec(svg);
  return m ? m[1] : null;
}

// A PNG's pixel size, from its IHDR chunk.
async function pngSize(file) {
  const buf = await readFile(file);
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
}

// Send requests down one daemon session and collect the responses by id.
// Rejects rather than hangs if the daemon stops answering.
function session(requests, ms = 30000) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [daemon, "--daemon"], { stdio: ["pipe", "pipe", "ignore"] });
    const out = new Map();
    const timer = setTimeout(() => { child.kill(); reject(new Error(`daemon timed out after ${ms}ms`)); }, ms);
    createInterface({ input: child.stdout }).on("line", (line) => {
      const r = JSON.parse(line);
      if (r.ready) {
        for (const q of requests) child.stdin.write(JSON.stringify(q) + "\n");
        return;
      }
      out.set(r.id, r);
      if (out.size === requests.length) {
        clearTimeout(timer);
        child.stdin.end();
        resolve(out);
      }
    });
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
  });
}

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  ok    ${name}`);
  } else {
    console.log(`  FAIL  ${name}${detail ? "  -- " + detail : ""}`);
    failures++;
  }
}

async function run() {
  const dir = await mkdtemp(path.join(tmpdir(), "eqnav-"));
  try {
    let i = 0;
    for (const eq of [...TRIGGERS, ...CONTROLS]) {
      const tex = path.join(dir, `eq${i}.tex`);
      const out = path.join(dir, `eq${i}.svg`);
      const png = path.join(dir, `eq${i}.png`);
      i++;
      await writeFile(tex, eq, "utf8");
      await execFileP("node", [daemon, "--in", tex, "--out", out, "--display"]);
      const svg = await readFile(out, "utf8");

      check(`serializes ${JSON.stringify(eq)}`, svg.startsWith("<svg"), svg.slice(0, 60));
      const bad = badAttribute(svg);
      check(`escapes attributes in ${JSON.stringify(eq)}`, bad === null, bad && `raw markup in ="${bad}"`);

      if (hasRsvg) {
        let rasterOk = true, err = "";
        try {
          await execFileP("rsvg-convert", ["-o", png, out]);
        } catch (e) {
          rasterOk = false;
          err = String(e.stderr || e.message).trim().slice(0, 120);
        }
        check(`rsvg-convert accepts ${JSON.stringify(eq)}`, rasterOk, err);
      }
    }
    for (const eq of COLOR_CASES) {
      const tex = path.join(dir, `color${i}.tex`);
      const out = path.join(dir, `color${i}.svg`);
      const png = path.join(dir, `color${i}.png`);
      i++;
      await writeFile(tex, eq, "utf8");
      await execFileP("node", [daemon, "--in", tex, "--out", out, "--display", "--color", COLOR]);
      const svg = await readFile(out, "utf8");

      const err = errorBox(svg);
      check(`colours ${JSON.stringify(eq)} without an error box`, err === null, err);
      check(`bakes the colour into ${JSON.stringify(eq)}`, svg.includes(`#${COLOR}`), svg.slice(0, 80));
      const left = /(?:fill|stroke)="currentColor"/.exec(svg);
      check(`resolves every currentColor in ${JSON.stringify(eq)}`, left === null, left && left[0]);

      if (hasRsvg) {
        let rasterOk = true, err2 = "";
        try {
          await execFileP("rsvg-convert", ["-o", png, out]);
        } catch (e) {
          rasterOk = false;
          err2 = String(e.stderr || e.message).trim().slice(0, 120);
        }
        check(`rsvg-convert accepts coloured ${JSON.stringify(eq)}`, rasterOk, err2);
      }
    }

    for (const eq of MACRO_CASES) {
      const tex = path.join(dir, `macro${i}.tex`);
      const out = path.join(dir, `macro${i}.svg`);
      i++;
      await writeFile(tex, eq, "utf8");
      await execFileP("node", [daemon, "--in", tex, "--out", out, "--display"]);
      const svg = await readFile(out, "utf8");
      const undef = undefinedMacro(svg);
      check(`defines ${JSON.stringify(eq)}`, undef === null, undef && `rendered as red text: ${undef}`);
    }

    for (const eq of TAG_CASES) {
      const tex = path.join(dir, `tag${i}.tex`);
      const out = path.join(dir, `tag${i}.svg`);
      const png = path.join(dir, `tag${i}.png`);
      i++;
      await writeFile(tex, eq, "utf8");
      await execFileP("node", [daemon, "--in", tex, "--out", out, "--display"]);
      const svg = await readFile(out, "utf8");
      const root = /<svg[^>]*>/.exec(svg)[0];

      const err = errorBox(svg);
      check(`renders ${JSON.stringify(eq)} without an error box`, err === null, err);
      const width = /\swidth="([^"]*)"/.exec(root);
      check(`gives ${JSON.stringify(eq)} an absolute width`, width && /px$/.test(width[1]), width && width[1]);
      check(`gives ${JSON.stringify(eq)} a viewBox`, /\sviewBox="/.test(root), root.slice(0, 160));

      if (hasRsvg) {
        await execFileP("rsvg-convert", ["-o", png, out]);
        const { w, h } = await pngSize(png);
        check(`rasterizes ${JSON.stringify(eq)} to a visible size`, w >= 50 && h >= 10, `${w}x${h}`);
      }
    }

    // Twice the same label, then a macro the preamble defined: the label must
    // not be a redefinition the second time, and whatever clears it must leave
    // the preamble's \newcommand in place.
    const preamble = "\\newcommand{\\eqnavtest}{Q}";
    const res = await session([
      { id: 1, equation: LABELLED, display: true, preamble },
      { id: 2, equation: LABELLED, display: true, preamble },
      { id: 3, equation: "\\eqnavtest", display: true, preamble },
    ]);
    for (const [id, what] of [[1, "labelled equation"], [2, "same label again"], [3, "preamble macro after both"]]) {
      const r = res.get(id);
      const err = r.ok ? errorBox(r.svg) || undefinedMacro(r.svg) : r.err;
      check(`one daemon session: ${what}`, r.ok && err === null, err);
    }

    // Inline math is one <svg>, all of it. MathJax splits inline math at every
    // place it could break, one <svg> each, and the daemon kept the first: this
    // came back as a lone `a` (#46).
    const INLINE = "a+b+c+d=e+f+g+h";
    const il = await session([
      { id: 1, equation: INLINE, display: false },
      { id: 2, equation: INLINE, display: true },
    ]);
    const [inl, disp] = [1, 2].map((id) => il.get(id));
    check(
      "renders all of an inline equation",
      inl.ok && Math.abs(inl.width - disp.width) < 1,
      inl.ok ? `inline ${inl.width}ex, display ${disp.width}ex` : inl.err
    );
    check("renders inline math as one <svg>", inl.ok && inl.svg.match(/<svg/g).length === 1);

    if (!hasRsvg) console.log("  note: rsvg-convert not on PATH, rasterization checks skipped");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }

  console.log(failures === 0 ? "\nall daemon specs passed" : `\n${failures} failure(s)`);
  process.exit(failures === 0 ? 0 : 1);
}

run();
