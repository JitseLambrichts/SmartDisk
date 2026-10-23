#!/usr/bin/env python3
"""Collect license notices from the resolved macOS Rust dependencies."""
import json
from pathlib import Path
import subprocess
import sys

metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--format-version", "1",
    "--filter-platform", "aarch64-apple-darwin",
]))
resolved = {node["id"] for node in metadata["resolve"]["nodes"]}
sections = ["SMART DISK — THIRD-PARTY NOTICES\n\n"
            "Notices for resolved third-party Rust dependencies. Some platform\n"
            "dependencies may not be used in this particular binary.\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] not in resolved or package["source"] is None:
        continue
    root = Path(package["manifest_path"]).parent
    files = {p for p in root.iterdir() if p.is_file()
             and p.name.lower().startswith(("license", "licence", "copying", "notice"))}
    if package.get("license_file"):
        files.add(root / package["license_file"])
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                    f"License: {package.get('license') or 'See license below'}\n"
                    f"Source: https://crates.io/crates/{package['name']}/{package['version']}\n")
    for path in sorted(files):
        if path.is_file():
            sections.append(f"\n--- {path.name} ---\n{path.read_text(errors='replace')}\n")
Path(sys.argv[1]).write_text("\n".join(sections), encoding="utf-8")
