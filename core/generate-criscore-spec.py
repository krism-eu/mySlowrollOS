#!/usr/bin/env python3
"""Generate the OBS criscore spec from a single protected RPM package list."""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SEED = ROOT / "core/protected.seed"
TEMPLATE = ROOT / "obs/criscore1/criscore1.spec.in"
OUTPUT = ROOT / "obs/criscore1/criscore1.spec"
MARKER = "@PROTECTED_REQUIRES@"


def get_packages():
    packages = [
        line.strip() for line in SEED.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not packages or len(packages) != len(set(packages)):
        raise ValueError("empty or duplicated protected package list")
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", p) for p in packages):
        raise ValueError("invalid RPM package name in protected.seed")
    if packages != sorted(packages):
        raise ValueError("protected.seed must be sorted")
    return packages


def generate():
    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count(MARKER) != 2:
        raise ValueError("expected two protected-requires template markers")
    requires = "\n".join(f"Requires:       {p}" for p in get_packages())
    return template.replace(MARKER, requires)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify generated OBS spec without rewriting it")
    args = parser.parse_args()
    expected = generate()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != expected:
            print("FAIL: criscore spec differs from protected.seed/template", file=sys.stderr)
            return 1
        print("PASS: criscore spec matches its seed and template")
    else:
        OUTPUT.write_text(expected, encoding="utf-8")
        print(f"Generated {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
