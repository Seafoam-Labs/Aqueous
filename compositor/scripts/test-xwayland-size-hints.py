#!/usr/bin/env python3
"""Exercise the production wlroots WM_NORMAL_HINTS decoder with real XCB replies."""
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]) / "xwayland/xwm.c"
    text = source.read_text()
    start = text.index("static void read_surface_normal_hints(")
    end = text.index("\n#define MWM_HINTS_FLAGS_FIELD", start)
    production = text[start:end]
    fixture = Path(__file__).parent / "fixtures/xwayland-size-hints.c"
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "xcb-icccm"], text=True))
    with tempfile.TemporaryDirectory(prefix="aqueous-size-hints-") as tmp:
        tmp = Path(tmp)
        (tmp / "decoder.h").write_text(production)
        binary = tmp / "test"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
                        "-I" + str(tmp), str(fixture), "-o", str(binary), *flags], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
