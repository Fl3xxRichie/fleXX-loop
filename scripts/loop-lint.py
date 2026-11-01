#!/usr/bin/env python3
"""loop-lint - validate fleXX-loop task files against the task contract.

Zero dependencies, stdlib only. Works on Windows and POSIX.

    python3 scripts/loop-lint.py .hermes/tasks
    python3 scripts/loop-lint.py .hermes/tasks/foo.md --json
    python3 scripts/loop-lint.py .hermes/tasks --strict   # warnings also fail

Exit codes: 0 clean, 1 findings at error level (or any finding under --strict),
2 usage error.

What it enforces (the rules the three skills depend on and nothing else does):

  * frontmatter parses, slug matches the filename, status is a known state
  * claimed_at exists exactly when status is in-progress
  * depends_on is a list, no self-dependency, no cycles, deps resolve
  * every task carries the five required sections
  * AC-N / NG-N ids are sequential, unique, and an AC never references an NG
  * state markers match status (built needs [BUILT, merged needs [MERGED)
  * reactivating a blocked task requires a ## Resolution section
"""

from __future__ import annotations

import json
import re
import sys
from datetime import date
from pathlib import Path

STATUSES = {"draft", "agent-ready", "in-progress", "built", "blocked", "merged"}
PRIORITIES = {"high", "normal", "low"}
REQUIRED_SECTIONS = [
    "## Problem",
    "## Acceptance Criteria",
    "## Non-goals",
    "## Relevant files",
    "## How to verify",
]
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:[T ][0-9:.+Z-]+)?$")
AC_RE = re.compile(r"^\s*-\s*\[[ xX]\]\s*AC-(\d+)\b(.*)$")
NG_RE = re.compile(r"^\s*-\s*NG-(\d+)\s*[:.]\s*(.*)$")
ANY_AC_LINE_RE = re.compile(r"^\s*-\s*\[[ xX]\]")
MARKER_BUILT = "[BUILT"
MARKER_MERGED = "[MERGED"
MARKER_BLOCKED = "[BLOCKED"


class Finding:
    __slots__ = ("path", "level", "code", "line", "message")

    def __init__(self, path, level, code, line, message):
        self.path = str(path)
        self.level = level
        self.code = code
        self.line = line
        self.message = message

    def as_dict(self):
        return {
            "file": self.path,
            "level": self.level,
            "code": self.code,
            "line": self.line,
            "message": self.message,
        }

    def __str__(self):
        where = f"{self.path}:{self.line}" if self.line else self.path
        return f"{where}: {self.level} {self.code} {self.message}"


def split_frontmatter(text):
    """Return (frontmatter_lines, body_lines, body_start_lineno)."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, lines, 1
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return lines[1:idx], lines[idx + 1 :], idx + 2
    return None, lines, 1


def parse_frontmatter(fm_lines):
    """Minimal YAML: scalars, inline [a, b] lists, and block '-' lists."""
    data = {}
    key = None
    for raw in fm_lines:
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        block_item = re.match(r"^\s+-\s+(.*)$", line)
        if block_item and key is not None:
            value = strip_quotes(block_item.group(1).strip())
            if not isinstance(data.get(key), list):
                data[key] = []
            data[key].append(value)
            continue
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        key, raw_value = m.group(1), m.group(2).strip()
        if raw_value == "":
            data[key] = []
            continue
        if raw_value.startswith("[") and raw_value.endswith("]"):
            inner = raw_value[1:-1].strip()
            data[key] = [strip_quotes(p.strip()) for p in inner.split(",") if p.strip()] if inner else []
            continue
        data[key] = strip_quotes(raw_value)
    return data


def strip_quotes(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def valid_date(value):
    if not isinstance(value, str) or not ISO_DATE_RE.match(value.strip()):
        return False
    try:
        date.fromisoformat(value.strip()[:10])
    except ValueError:
        return False
    return True


def lint_file(path, findings):
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as exc:
        findings.append(Finding(path, "ERROR", "E000", 0, f"cannot read file: {exc}"))
        return None

    fm_lines, body_lines, body_start = split_frontmatter(text)
    if fm_lines is None:
        findings.append(Finding(path, "ERROR", "E001", 1, "missing YAML frontmatter (file must start with ---)"))
        return None

    fm = parse_frontmatter(fm_lines)
    stem = path.stem

    slug = fm.get("slug")
    if not isinstance(slug, str) or not slug:
        findings.append(Finding(path, "ERROR", "E002", 1, "frontmatter is missing 'slug'"))
    else:
        if slug != stem:
            findings.append(Finding(path, "ERROR", "E003", 1, f"slug '{slug}' does not match filename '{stem}.md'"))
        if not SLUG_RE.match(slug):
            findings.append(Finding(path, "ERROR", "E004", 1, f"slug '{slug}' is not kebab-case ([a-z0-9-])"))

    status = fm.get("status")
    if not isinstance(status, str) or not status:
        findings.append(Finding(path, "ERROR", "E005", 1, "frontmatter is missing 'status'"))
        status = None
    elif status not in STATUSES:
        findings.append(
            Finding(path, "ERROR", "E005", 1, f"status '{status}' is not one of {sorted(STATUSES)}")
        )

    created = fm.get("created")
    if created is None:
        findings.append(Finding(path, "ERROR", "E006", 1, "frontmatter is missing 'created'"))
    elif not valid_date(created):
        findings.append(Finding(path, "ERROR", "E006", 1, f"created '{created}' is not an ISO date"))

    priority = fm.get("priority")
    if priority not in (None, "") and priority not in PRIORITIES:
        findings.append(
            Finding(path, "ERROR", "E007", 1, f"priority '{priority}' is not one of {sorted(PRIORITIES)}")
        )

    claimed = fm.get("claimed_at")
    if status == "in-progress" and not claimed:
        findings.append(Finding(path, "ERROR", "E008", 1, "status is in-progress but claimed_at is missing"))
    if claimed and status != "in-progress":
        findings.append(
            Finding(path, "WARN", "W001", 1, f"claimed_at is set but status is '{status}' - stale lock field")
        )

    deps = fm.get("depends_on")
    if deps is None:
        deps = []
    if isinstance(deps, str):
        findings.append(Finding(path, "ERROR", "E009", 1, "depends_on must be a list, not a string"))
        deps = []
    if slug in deps:
        findings.append(Finding(path, "ERROR", "E009", 1, "depends_on lists the task itself"))

    # --- body ---
    body = "\n".join(body_lines)
    for section in REQUIRED_SECTIONS:
        if not re.search(rf"^{re.escape(section)}\s*$", body, re.MULTILINE):
            findings.append(Finding(path, "ERROR", "E020", body_start, f"required section missing: {section}"))

    acs = []
    ngs = []
    for offset, line in enumerate(body_lines):
        lineno = body_start + offset
        ac = AC_RE.match(line)
        if ac:
            acs.append((int(ac.group(1)), lineno, ac.group(2)))
            continue
        ng = NG_RE.match(line)
        if ng:
            ngs.append((int(ng.group(1)), lineno, ng.group(2)))

    if not acs:
        findings.append(Finding(path, "ERROR", "E021", body_start, "no acceptance criteria found (expected '- [ ] AC-1 - ...')"))

    def check_sequence(items, prefix, code):
        seen = {}
        for number, lineno, _text in items:
            if number in seen:
                findings.append(
                    Finding(path, "ERROR", code, lineno, f"duplicate {prefix}-{number} (first seen line {seen[number]})")
                )
                continue
            seen[number] = lineno
        if seen:
            expected = list(range(1, max(seen) + 1))
            for missing in [n for n in expected if n not in seen]:
                findings.append(Finding(path, "ERROR", code, 0, f"missing {prefix}-{missing} - ids must be sequential from 1"))

    check_sequence(acs, "AC", "E022")
    check_sequence(ngs, "NG", "E023")

    ng_ids = {n for n, _l, _t in ngs}
    for number, lineno, ac_text in acs:
        referenced = {int(m) for m in re.findall(r"\bNG-(\d+)\b", ac_text)}
        for ng in sorted(referenced & ng_ids):
            findings.append(
                Finding(
                    path,
                    "ERROR",
                    "E024",
                    lineno,
                    f"AC-{number} references NG-{ng} - an acceptance criterion may not require a non-goal",
                )
            )
        if re.search(r"<(?:[a-z][a-z0-9 _/-]{1,30})>", ac_text) or "TODO" in ac_text.upper():
            findings.append(Finding(path, "WARN", "W003", lineno, f"AC-{number} contains a placeholder or TODO"))

    # AC list items written without the checkbox form are invisible to the contract
    in_ac = False
    for offset, line in enumerate(body_lines):
        if re.match(r"^##\s+Acceptance Criteria\s*$", line.strip()):
            in_ac = True
            continue
        if in_ac and line.startswith("## "):
            in_ac = False
        if in_ac and line.strip().startswith("- ") and not ANY_AC_LINE_RE.match(line):
            findings.append(
                Finding(
                    path,
                    "WARN",
                    "W004",
                    body_start + offset,
                    "acceptance criterion lacks the '- [ ] AC-N' form and will not be parsed",
                )
            )

    # --- state markers ---
    if status in {"built", "merged"} and MARKER_BUILT not in body:
        findings.append(Finding(path, "ERROR", "E030", 0, f"status is '{status}' but there is no [BUILT <sha> <date>] record"))
    if status == "merged" and MARKER_MERGED not in body:
        findings.append(Finding(path, "ERROR", "E031", 0, "status is merged but there is no [MERGED <sha> <date>] record"))
    if status == "blocked" and MARKER_BLOCKED not in body:
        findings.append(Finding(path, "WARN", "W007", 0, "status is blocked but there is no [BLOCKED <date>] question record"))
    if status == "agent-ready" and MARKER_BLOCKED in body and "## Resolution" not in body:
        findings.append(
            Finding(
                path,
                "ERROR",
                "E032",
                body_start,
                "task was blocked and is agent-ready again without a '## Resolution' section",
            )
        )
    if body.count(MARKER_BUILT) > 1:
        findings.append(Finding(path, "WARN", "W006", 0, "more than one [BUILT marker - write the marker idempotently"))

    return {"path": path, "slug": slug, "status": status, "deps": deps}


def check_cycles(files, findings):
    graph = {f["slug"]: [d for d in f["deps"]] for f in files if isinstance(f.get("slug"), str)}
    known = set(graph)

    for node, deps in graph.items():
        for dep in deps:
            if dep and dep not in known:
                findings.append(
                    Finding(node, "WARN", "W002", 0, f"depends_on '{dep}' has no task file in the linted set")
                )

    WHITE, GREY, BLACK = 0, 1, 2
    color = {node: WHITE for node in graph}

    def visit(node, stack):
        color[node] = GREY
        for dep in graph.get(node, []):
            if dep not in graph:
                continue
            if color[dep] == GREY:
                cycle = " -> ".join(stack + [dep])
                findings.append(Finding(node, "ERROR", "E010", 0, f"dependency cycle: {cycle}"))
            elif color[dep] == WHITE:
                visit(dep, stack + [dep])
        color[node] = BLACK

    for node in graph:
        if color[node] == WHITE:
            visit(node, [node])


def collect(targets):
    files = []
    for target in targets:
        path = Path(target)
        if path.is_dir():
            files.extend(sorted(p for p in path.glob("*.md") if p.is_file()))
        elif path.is_file():
            files.append(path)
        else:
            print(f"loop-lint: no such file or directory: {target}", file=sys.stderr)
            raise SystemExit(2)
    return files


def main(argv):
    args = [a for a in argv[1:]]
    as_json = "--json" in args
    strict = "--strict" in args
    quiet = "--quiet" in args
    if "-h" in args or "--help" in args:
        print(__doc__)
        return 0
    targets = [a for a in args if not a.startswith("-")] or [".hermes/tasks"]

    files = collect(targets)
    findings = []
    parsed = []
    for path in files:
        result = lint_file(path, findings)
        if result:
            parsed.append(result)
    check_cycles(parsed, findings)

    errors = [f for f in findings if f.level == "ERROR"]
    warnings = [f for f in findings if f.level == "WARN"]

    if as_json:
        print(
            json.dumps(
                {
                    "files": len(files),
                    "errors": len(errors),
                    "warnings": len(warnings),
                    "findings": [f.as_dict() for f in findings],
                },
                indent=2,
            )
        )
    else:
        for finding in findings:
            print(finding)
        if not quiet:
            print(f"loop-lint: {len(files)} file(s), {len(errors)} error(s), {len(warnings)} warning(s)")

    if errors:
        return 1
    if strict and warnings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
