#!/usr/bin/env python3
"""Tests for scripts/loop-lint.py. Stdlib unittest, no fixtures on disk.

    python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINT_PATH = ROOT / "scripts" / "loop-lint.py"

spec = importlib.util.spec_from_file_location("loop_lint", LINT_PATH)
loop_lint = importlib.util.module_from_spec(spec)
sys.modules["loop_lint"] = loop_lint
spec.loader.exec_module(loop_lint)

GOOD = """---
slug: {slug}
status: {status}
depends_on: {deps}
created: 2026-11-02
priority: normal
---

## Problem
Users cannot do the thing.

## Acceptance Criteria
- [ ] AC-1 - The thing works.
- [ ] AC-2 - The thing is visible from the homepage.

## Non-goals
- NG-1: No schema changes.

## Relevant files
- src/app.ts - mounts the thing

## How to verify
1. Open /thing and check it renders.
"""


def good(slug="thing", status="draft", deps="[]"):
    return GOOD.format(slug=slug, status=status, deps=deps)


class LintCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, slug, text):
        path = self.dir / f"{slug}.md"
        path.write_text(text, encoding="utf-8")
        return path

    def run_lint(self, *args):
        return loop_lint.main(["loop-lint", str(self.dir), *args])

    def findings(self):
        collected = []
        for path in sorted(self.dir.glob("*.md")):
            loop_lint.lint_file(path, collected)
        return collected

    def codes(self, level=None):
        return {f.code for f in self.findings() if level is None or f.level == level}

    def test_clean_task_passes(self):
        self.write("thing", good())
        self.assertEqual(self.run_lint(), 0)

    def test_slug_must_match_filename(self):
        self.write("thing", good(slug="other"))
        self.assertIn("E003", self.codes())

    def test_slug_charset(self):
        self.write("Thing_One", good(slug="Thing_One"))
        self.assertIn("E004", self.codes())

    def test_unknown_status(self):
        self.write("thing", good(status="ready"))
        self.assertIn("E005", self.codes())

    def test_in_progress_requires_claimed_at(self):
        self.write("thing", good(status="in-progress"))
        self.assertIn("E008", self.codes())

    def test_stale_claimed_at_warns(self):
        text = good(status="built").replace("priority: normal", "priority: normal\nclaimed_at: 2026-11-01T10:00:00Z")
        text += "\n[BUILT abc1234 2026-11-02T10:00:00Z]\n"
        self.write("thing", text)
        self.assertIn("W001", self.codes("WARN"))

    def test_built_without_marker(self):
        self.write("thing", good(status="built"))
        self.assertIn("E030", self.codes())

    def test_merged_requires_merged_marker(self):
        text = good(status="merged") + "\n[BUILT abc1234 2026-11-02T10:00:00Z]\n"
        self.write("thing", text)
        self.assertIn("E031", self.codes())

    def test_missing_section(self):
        text = good().replace("## Non-goals\n- NG-1: No schema changes.\n", "")
        self.write("thing", text)
        self.assertIn("E020", self.codes())

    def test_no_acceptance_criteria(self):
        text = good().split("## Acceptance Criteria")[0] + "## Acceptance Criteria\n\n## Non-goals\n- NG-1: x\n"
        self.write("thing", text)
        self.assertIn("E021", self.codes())

    def test_non_sequential_ac_ids(self):
        text = good().replace("- [ ] AC-2 - The thing is visible from the homepage.", "- [ ] AC-3 - Visible.")
        self.write("thing", text)
        self.assertIn("E022", self.codes())

    def test_duplicate_ng_ids(self):
        text = good().replace("- NG-1: No schema changes.", "- NG-1: No schema changes.\n- NG-1: Dup.")
        self.write("thing", text)
        self.assertIn("E023", self.codes())

    def test_ac_referencing_non_goal(self):
        text = good().replace("- [ ] AC-2 - The thing is visible from the homepage.", "- [ ] AC-2 - Do NG-1 anyway.")
        self.write("thing", text)
        self.assertIn("E024", self.codes())

    def test_checkbox_less_ac_warns(self):
        text = good().replace("- [ ] AC-2 - The thing is visible from the homepage.", "- AC-2 - Visible.")
        self.write("thing", text)
        self.assertIn("W004", self.codes("WARN"))

    def test_reactivated_blocked_needs_resolution(self):
        text = good(status="agent-ready") + "\n[BLOCKED 2026-11-01]\nWhich tier?\n"
        self.write("thing", text)
        self.assertIn("E032", self.codes())

    def test_resolution_satisfies_reactivation(self):
        text = good(status="agent-ready") + "\n[BLOCKED 2026-11-01]\n\n## Resolution\nPro tier.\n"
        self.write("thing", text)
        self.assertEqual(self.run_lint(), 0)

    def test_self_dependency(self):
        self.write("thing", good(deps="[thing]"))
        self.assertIn("E009", self.codes())

    def test_cycle_detected(self):
        self.write("a", good(slug="a", deps="[b]"))
        self.write("b", good(slug="b", deps="[a]"))
        collected = []
        parsed = [loop_lint.lint_file(p, collected) for p in sorted(self.dir.glob("*.md"))]
        loop_lint.check_cycles([p for p in parsed if p], collected)
        self.assertIn("E010", {f.code for f in collected})

    def test_unknown_dependency_warns(self):
        self.write("thing", good(deps="[ghost]"))
        collected = []
        parsed = [loop_lint.lint_file(p, collected) for p in sorted(self.dir.glob("*.md"))]
        loop_lint.check_cycles([p for p in parsed if p], collected)
        self.assertIn("W002", {f.code for f in collected})

    def test_strict_promotes_warnings_to_failure(self):
        text = good().replace("- [ ] AC-2 - The thing is visible from the homepage.", "- AC-2 - Visible.")
        self.write("thing", text)
        self.assertEqual(self.run_lint(), 0)
        self.assertEqual(self.run_lint("--strict"), 1)

    def test_missing_frontmatter(self):
        self.write("thing", "# just a heading\n")
        self.assertIn("E001", self.codes())

    def test_json_output_shape(self):
        import io
        import json
        from contextlib import redirect_stdout

        self.write("thing", good(slug="other"))
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.run_lint("--json")
        payload = json.loads(buf.getvalue())
        self.assertEqual(payload["files"], 1)
        self.assertGreaterEqual(payload["errors"], 1)
        self.assertTrue(all({"file", "level", "code", "line", "message"} <= set(f) for f in payload["findings"]))


class BundledSkillCase(unittest.TestCase):
    """The skills reference files; those files must exist in the repo."""

    def test_every_skill_has_frontmatter(self):
        for skill in sorted((ROOT / "skills").glob("*/SKILL.md")):
            text = skill.read_text(encoding="utf-8-sig")
            self.assertTrue(text.startswith("---"), f"{skill} has no frontmatter")
            fm = loop_lint.parse_frontmatter(loop_lint.split_frontmatter(text)[0] or [])
            self.assertIn("name", fm, f"{skill} frontmatter has no name")
            self.assertIn("description", fm, f"{skill} frontmatter has no description")
            self.assertEqual(fm["name"], skill.parent.name, f"{skill} name does not match its directory")

    def test_referenced_assets_exist(self):
        import re

        for skill in sorted((ROOT / "skills").glob("*/SKILL.md")):
            text = skill.read_text(encoding="utf-8-sig")
            for ref in set(re.findall(r"`(references/[\w./-]+\.md)`", text)):
                self.assertTrue((skill.parent / ref).is_file(), f"{skill} references missing {ref}")
            for ref in set(re.findall(r"`(scripts/[\w./-]+)`", text)):
                self.assertTrue((skill.parent / ref).is_file(), f"{skill} references missing {ref}")


if __name__ == "__main__":
    unittest.main()
