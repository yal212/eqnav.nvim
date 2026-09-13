#!/usr/bin/env python3
"""Display a rendered equation using the Kitty graphics protocol.

Run this inside the terminal you actually use. If you see an equation, eqnav's
image backend will work there. If you see nothing (or stray escape codes), it
won't, and eqnav will fall back to its text backend or HTML export.

Handles the tmux case: inside tmux the escape must be wrapped in a DCS
passthrough with every inner ESC doubled, and tmux needs `allow-passthrough on`.
"""
import base64, os, subprocess, sys

ESC = "\x1b"

def in_tmux():
    return bool(os.environ.get("TMUX"))

def passthrough(seq: str) -> str:
    if not in_tmux():
        return seq
    return ESC + "Ptmux;" + seq.replace(ESC, ESC * 2) + ESC + "\\"

def show(path: str):
    # a=T transmit+display, f=100 PNG, t=f medium is a file path (base64'd)
    b64 = base64.standard_b64encode(path.encode()).decode()
    seq = f"{ESC}_Ga=T,f=100,t=f;{b64}{ESC}\\"
    sys.stdout.write(passthrough(seq))
    sys.stdout.flush()

def diag():
    print("diagnostics")
    print(f"  TERM              {os.environ.get('TERM', '?')}")
    print(f"  TERM_PROGRAM      {os.environ.get('TERM_PROGRAM', '?')}")
    print(f"  inside tmux       {in_tmux()}")
    if in_tmux():
        try:
            v = subprocess.run(["tmux", "show", "-gv", "allow-passthrough"],
                               capture_output=True, text=True).stdout.strip()
            print(f"  allow-passthrough {v or '(unset -- needs to be on)'}")
            t = subprocess.run(["tmux", "display", "-p", "#{client_termtype}"],
                               capture_output=True, text=True).stdout.strip()
            print(f"  outer terminal    {t}")
        except FileNotFoundError:
            pass

if __name__ == "__main__":
    png = sys.argv[1] if len(sys.argv) > 1 else "/tmp/eqnav-p0/c.png"
    if not os.path.exists(png):
        sys.exit(f"no such file: {png}")
    diag()
    print("\nbelow this line you should see a rendered  E = mc^2  :\n")
    show(os.path.abspath(png))
    print("\n\nif the line above is blank, terminal graphics are not reaching this pane.")
