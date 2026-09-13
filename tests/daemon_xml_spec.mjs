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
    if (!hasRsvg) console.log("  note: rsvg-convert not on PATH, rasterization checks skipped");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }

  console.log(failures === 0 ? "\nall daemon specs passed" : `\n${failures} failure(s)`);
  process.exit(failures === 0 ? 0 : 1);
}

run();
