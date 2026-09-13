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
//   node tests/daemon_xml_spec.mjs
//
import { execFile, spawnSync } from "node:child_process";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
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

// MathJax bakes a failure into the image as a <merror> box, so a render that
// "succeeded" can still be a picture of an error message. This is the assertion
// render_spec.lua was missing -- "a non-empty PNG appeared" is satisfied by one.
function errorBox(svg) {
  const m = /data-mjx-error="([^"]*)"/.exec(svg);
  return m ? m[1] : null;
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

    if (!hasRsvg) console.log("  note: rsvg-convert not on PATH, rasterization checks skipped");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }

  console.log(failures === 0 ? "\nall daemon specs passed" : `\n${failures} failure(s)`);
  process.exit(failures === 0 ? 0 : 1);
}

run();
