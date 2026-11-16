#!/usr/bin/env python3
"""Offline static checks for the public plugin snapshot; no Lua is executed."""
import hashlib
from datetime import date
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SENSITIVE = re.compile(
    r"-----BEGIN [A-Z ]*" + r"PRIVATE KEY-----|"
    r"gh" + r"[pousr]_[A-Za-z0-9]{20,}|"
    r"github" + r"_pat_[A-Za-z0-9_]{30,}|"
    r"A" + r"KIA[0-9A-Z]{16}"
)


class CheckFailure(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def version(value):
    require(isinstance(value, str) and SEMVER.fullmatch(value), "invalid version")
    return tuple(map(int, value.split(".")))


def release_notes(changelog, value):
    version(value)
    headings = list(re.finditer(r"^## " + re.escape(value) + r"(?:[ \t].*)?$", changelog, re.M))
    require(len(headings) == 1, "release notes require exactly one version heading")
    heading = headings[0]
    stamp = re.fullmatch(r"## " + re.escape(value) + r" — (\d{4}-\d{2}-\d{2})", heading[0])
    require(stamp, "release heading must use version and ISO date")
    try:
        date.fromisoformat(stamp[1])
    except ValueError:
        raise CheckFailure("invalid release date")
    remaining = changelog[heading.end():]
    boundary = re.search(r"^## ", remaining, re.M)
    body = (remaining[:boundary.start()] if boundary else remaining).strip()
    groups = body.split("\n\n")
    require(len(groups) == 4 and groups[0] == "### 中文" and groups[2] == "### English",
            "release notes require Chinese then English headings and bullet groups")
    chinese, english = groups[1].splitlines(), groups[3].splitlines()
    require(chinese and len(chinese) == len(english), "release translation counts must match")
    for line in chinese:
        require(line.startswith("- ") and line.endswith("。") and re.search(r"[\u4e00-\u9fff]", line),
                "invalid Chinese release bullet")
    for line in english:
        require(re.match(r"^- [A-Za-z]", line) and line.endswith("."), "invalid English release bullet")
    return {"title": "PicaYomi " + value, "tag": "v" + value,
            "date": stamp[1], "body": body + "\n"}


def check_changelog(changelog, current):
    headings = re.findall(r"^## (.*)$", changelog, re.M)
    require(headings, "missing release headings")
    versions = []
    for heading in headings:
        match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+) — \d{4}-\d{2}-\d{2}", heading)
        require(match, "invalid changelog version heading")
        versions.append(match[1])
        release_notes(changelog, match[1])
    require(versions[0] == current, "current release must be first in changelog")
    require(len(versions) == len(set(versions)), "duplicate changelog release")
    return versions


def check_release_notes(actual, expected):
    require(actual.get("tag_name") == expected["tag"], "release tag differs from changelog")
    require(actual.get("name") == expected["title"], "release title differs from canonical title")
    require((actual.get("body") or "").replace("\r\n", "\n") == expected["body"],
            "release body differs from changelog")


def files():
    paths = []
    forbidden = {".aws", ".codex", ".agents", ".ssh", "personal", "dist",
                 "data", "cache", "test", "tools", "extensions", "source-repo"}
    for base, dirs, names in os.walk(ROOT, followlinks=False):
        if Path(base) == ROOT and ".git" in dirs:
            dirs.remove(".git")
        for name in dirs + names:
            path = Path(base) / name
            relative = path.relative_to(ROOT)
            require(not path.is_symlink(), "symlink in repository")
            require(relative.parts[0] not in forbidden, "private or build path in repository")
            require(not name.startswith((".env", "config.json", "settings.reader.lua", ".kindle"))
                    and not name.endswith((".credentials", ".log", ".sdr")),
                    "runtime or credential file in repository")
            if path.is_file():
                paths.append(path)
    return sorted(paths)


def check_text(path):
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return  # Screenshots are checked at publication time.
    require(not SENSITIVE.search(text), "possible credential in " + path.relative_to(ROOT).as_posix())
    if path.suffix == ".md":
        for target in re.findall(r"\]\(([^\s)]+)\)", text):
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            local = unquote(parsed.path)
            resolved = ((ROOT / local.lstrip("/")) if local.startswith("/")
                        else (path.parent / local)).resolve()
            require(resolved.is_relative_to(ROOT) and resolved.exists(),
                    "broken local link in " + path.relative_to(ROOT).as_posix())


def compile_lua(path, label):
    result = subprocess.run(["luajit", "-b", str(path), os.devnull],
                            capture_output=True, timeout=20)
    # Compiler output can contain source text; report the location only.
    require(result.returncode == 0, "Lua syntax error in " + label)


def check_bundles(host):
    folder = ROOT / "bundled"
    if host >= (1, 6, 0):
        require(not folder.exists(), "source-free release must not contain bundled sources")
        require((ROOT / "source/extensions/default_repository.lua").is_file(),
                "source-free release requires the default subscription")
        return 0
    require((folder / "index.json").is_file(), "missing bundled source inventory")
    index = json.loads((folder / "index.json").read_text())
    expected = {"picacg", "jm", "htcomic"}
    require(isinstance(index, list) and len(index) == len(expected), "invalid bundle inventory")
    require({e["id"] for e in index} == expected, "invalid bundle IDs")
    require({p.name for p in folder.iterdir()} == {"index.json", *(s + ".pysource" for s in expected)},
            "unexpected bundled file")
    count = 0
    with tempfile.TemporaryDirectory(prefix="picayomi-syntax-") as temp:
        source = Path(temp) / "module.lua"
        for entry in index:
            source_id = entry["id"]
            raw = (folder / (source_id + ".pysource")).read_bytes()
            require(hashlib.sha256(raw).hexdigest() == entry["sha256"], "bundle checksum mismatch")
            package = json.loads(raw)
            manifest, modules = package["manifest"], package["files"]
            require(package["format"] == 1 and manifest["id"] == source_id
                    and manifest["api_version"] == 3, "invalid bundle manifest")
            version(manifest["version"])
            minimum = version(manifest["min_app_version"])
            require(minimum <= host, "bundle requires newer plugin")
            if "max_app_version" in manifest:
                maximum = version(manifest["max_app_version"])
                require(minimum <= maximum and host <= maximum, "bundle incompatible with plugin")
            require(manifest["entry"] in modules, "missing bundle entry point")
            for name, code in modules.items():
                relative = PurePosixPath(name)
                require(isinstance(code, str) and not relative.is_absolute()
                        and ".." not in relative.parts and "\\" not in name
                        and relative.suffix == ".lua", "invalid bundle module path")
                source.write_text(code, encoding="utf-8")
                compile_lua(source, "bundled/" + source_id + "/" + name)
                count += 1
    return count


def main():
    require(shutil.which("luajit"), "LuaJIT is required")
    paths = files()
    for path in paths:
        check_text(path)
        if path.suffix == ".lua":
            compile_lua(path, path.relative_to(ROOT).as_posix())
    match = re.search(r'\bversion\s*=\s*"([^"\n]+)"', (ROOT / "_meta.lua").read_text())
    require(match, "missing plugin version")
    host = version(match[1])
    check_changelog((ROOT / "CHANGELOG.md").read_text(), match[1])
    gate = (ROOT / "util/log_config.lua").read_text()
    require(re.fullmatch(r"\s*return\s*\{\s*debug\s*=\s*false\s*,\s*allow_env\s*=\s*false\s*\}\s*",
                         re.sub(r"--[^\n]*", "", gate)), "release debug gate must be disabled")
    modules = check_bundles(host)
    print(f"PASS: {len(paths)} files, local documentation links, release gate, Lua syntax, "
          f"and {modules} bundled modules checked (static checks only).")


if __name__ == "__main__":
    try:
        main()
    except CheckFailure as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
        # Never echo exceptions containing source contents or matched credentials.
        print("FAIL: repository static checks failed. Check paths, links, versions, bundles and Lua syntax.",
              file=sys.stderr)
        sys.exit(1)
