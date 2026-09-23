#!/usr/bin/env bash
# Regenerate the README's demo assets from doc/demo.md (#29).
#
#   scripts/record-demo.sh record        open the demo for a screen recording
#   scripts/record-demo.sh gif FILE.mov  turn that recording into doc/demo.gif
#   scripts/record-demo.sh export        render doc/demo-export.png, headlessly
#
# The GIF needs a terminal that draws images, so it cannot be captured
# headlessly, and this script cannot start the macOS screen recorder for you:
# `record` prints the steps and opens the sandbox, you drive it. Every run
# uses a throwaway render cache, so what gets recorded is evidence the render
# path works rather than evidence a cache exists.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

demo=doc/demo.md
gif=doc/demo.gif
png=doc/demo-export.png

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

record() {
  make .tests/snacks.nvim >/dev/null
  cat <<EOF
Recording doc/demo.gif:

  1. Use Ghostty or Kitty, about 120x32, with a font size you would read at.
  2. Press Enter below. nvim opens $demo with an empty render cache.
  3. Start the screen recorder (Cmd-Shift-5, "Record Selected Portion") on
     the terminal window.
  4. :Eqnav, wait for every equation to appear, walk down with j, back up
     with k, then <CR> on an entry to land on it in the source.
  5. Stop the recording, quit nvim, and run:

       scripts/record-demo.sh gif ~/Desktop/<the recording>.mov

EOF
  read -r -p "Press Enter to open the demo... "
  XDG_CACHE_HOME=$(mktemp -d) nvim -u tests/manual_init.lua "$demo"
}

to_gif() {
  local mov=${1:-}
  [[ -f $mov ]] || { echo "no such recording: '$mov'" >&2; exit 1; }
  command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
  local palette filters="fps=12,scale=960:-1:flags=lanczos"
  palette=$(mktemp -d)/palette.png
  # Two passes: a palette built from this recording, then the GIF drawn with
  # it. The default 256-colour palette bands the anti-aliased glyph edges.
  ffmpeg -loglevel error -y -i "$mov" -vf "$filters,palettegen=stats_mode=diff" "$palette"
  ffmpeg -loglevel error -y -i "$mov" -i "$palette" \
    -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5" "$gif"
  echo "wrote $gif ($(du -h "$gif" | cut -f1))"
}

chrome() {
  local c
  for c in "${CHROME:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    google-chrome chromium chromium-browser; do
    [[ -n $c ]] && command -v "$c" >/dev/null && { echo "$c"; return; }
  done
  echo "no Chrome or Chromium found; set CHROME to its binary" >&2
  exit 1
}

export_png() {
  local browser tmp
  browser=$(chrome)
  tmp=$(mktemp -d)
  # Render and write the page the way :EqnavExport does, but through write():
  # export_and_open() ends in vim.ui.open and would launch a browser.
  cat >"$tmp/export.lua" <<EOF
local buf = vim.api.nvim_get_current_buf()
local eqs = require("eqnav.scan").scan(buf)
local left, failed = #eqs, {}
require("eqnav.render").render_all(eqs, function(i, png, err)
  left = left - 1
  if not png then
    table.insert(failed, ("#%d: %s"):format(i, tostring(err)))
  end
end)
if not vim.wait(120000, function() return left == 0 end, 50) then
  failed[#failed + 1] = "timed out with " .. left .. " left"
end
if #failed > 0 then
  io.stderr:write(table.concat(failed, "\n") .. "\n")
  vim.cmd("cquit 1")
end
require("eqnav.export.html").write(eqs, buf, "$tmp/demo.html")
vim.cmd("qall!")
EOF
  XDG_CACHE_HOME="$tmp/cache" nvim --headless -u tests/minimal_init.lua "$demo" \
    -c "luafile $tmp/export.lua"
  "$browser" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --blink-settings=preferredColorScheme=0 --virtual-time-budget=5000 \
    --window-size=1000,983 --screenshot="$root/$png" "file://$tmp/demo.html" 2>/dev/null
  echo "wrote $png"
}

case ${1:-} in
  record) record ;;
  gif) to_gif "${2:-}" ;;
  export) export_png ;;
  *) usage ;;
esac
