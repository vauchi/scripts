#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for jscpd-new-clones.py: a clone counts as new only if
main had no clone of the same two files at the same place. jscpd's own
baseline matches clones by their text, so a rename running through old
duplicates reported every one of them as new (vauchi/private#1359:
core!2411, 44 clones, all on main at the same lines)."""

import importlib.util
import json
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "jscpd-new-clones.py"
SPEC = importlib.util.spec_from_file_location("jscpd_new_clones", MODULE_PATH)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def clone(first, first_start, second, second_start, lines=12, is_new=True):
    return {
        "firstFile": {"name": first, "start": first_start, "end": first_start + lines},
        "secondFile": {"name": second, "start": second_start, "end": second_start + lines},
        "lines": lines,
        "isNew": is_new,
        "fragment": "fn x() {}",
    }


def report(*clones, duplicated_lines=None):
    lines = sum(c["lines"] for c in clones) if duplicated_lines is None else duplicated_lines
    return {
        "duplicates": list(clones),
        "statistics": {"total": {"clones": len(clones), "duplicatedLines": lines}},
    }


def test_a_clone_whose_text_changed_in_place_is_not_new():
    branch = report(clone("a.rs", 10, "b.rs", 40))
    main = report(clone("a.rs", 10, "b.rs", 40, is_new=False))
    assert CHECK.new_clones(branch, main, renames={}) == []


def test_a_clone_moved_a_few_lines_is_not_new():
    branch = report(clone("a.rs", 13, "b.rs", 38))
    main = report(clone("a.rs", 10, "b.rs", 40))
    assert CHECK.new_clones(branch, main, renames={}) == []


def test_the_two_files_may_be_listed_either_way_round():
    branch = report(clone("b.rs", 40, "a.rs", 10))
    main = report(clone("a.rs", 10, "b.rs", 40))
    assert CHECK.new_clones(branch, main, renames={}) == []


def test_a_file_renamed_since_main_keeps_its_clones():
    branch = report(clone("crypto/x25519.rs", 20, "exchange/x3dh.rs", 60))
    main = report(clone("crypto/x3dh.rs", 20, "exchange/x3dh.rs", 60))
    renames = {"crypto/x25519.rs": "crypto/x3dh.rs"}
    assert CHECK.new_clones(branch, main, renames=renames) == []


def test_a_clone_main_did_not_have_is_new():
    fresh = clone("a.rs", 200, "c.rs", 5)
    branch = report(clone("a.rs", 10, "b.rs", 40), fresh)
    main = report(clone("a.rs", 10, "b.rs", 40))
    assert CHECK.new_clones(branch, main, renames={}) == [fresh]


def test_the_same_files_far_from_main_clone_are_new():
    far = clone("a.rs", 300, "b.rs", 40)
    branch = report(far)
    main = report(clone("a.rs", 10, "b.rs", 40))
    assert CHECK.new_clones(branch, main, renames={}) == [far]


def test_a_clone_jscpd_already_matched_by_text_is_never_new():
    branch = report(clone("a.rs", 10, "z.rs", 1, is_new=False))
    assert CHECK.new_clones(branch, report(), renames={}) == []


def test_renames_are_read_from_git_name_status():
    status = "R100\tsrc/crypto/x3dh.rs\tsrc/crypto/x25519.rs\nM\tsrc/lib.rs\nR087\told.rs\tnew.rs\n"
    assert CHECK.renames_from_name_status(status) == {
        "src/crypto/x25519.rs": "src/crypto/x3dh.rs",
        "new.rs": "old.rs",
    }


REMOVED_25_ABOVE = """diff --git a/card_tests.rs b/card_tests.rs
index 1111111..2222222 100644
--- a/card_tests.rs
+++ b/card_tests.rs
@@ -14,25 +13,0 @@ use vauchi_core::{
-fn create_test_vauchi() -> Vauchi {
"""


def test_a_changed_clone_that_lines_removed_above_moved_far_is_not_new():
    # core!2420: a rename changed the clone's text, so jscpd flagged it,
    # and 25 lines removed above both copies moved them past LINE_SLACK.
    branch = report(clone("card_tests.rs", 131, "card_tests.rs", 284))
    main = report(clone("card_tests.rs", 156, "card_tests.rs", 309))
    shifts = CHECK.line_shifts_from_diff(REMOVED_25_ABOVE)
    assert CHECK.new_clones(branch, main, renames={}, shifts=shifts) == []


def test_lines_added_above_a_clone_move_it_too():
    diff = (
        "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n"
        "@@ -10,0 +11,30 @@\n" + "+added\n" * 30
    )
    branch = report(clone("a.rs", 70, "b.rs", 40))
    main = report(clone("a.rs", 40, "b.rs", 40))
    shifts = CHECK.line_shifts_from_diff(diff)
    assert CHECK.new_clones(branch, main, renames={}, shifts=shifts) == []


def test_a_clone_still_far_from_main_after_the_shift_is_new():
    far = clone("card_tests.rs", 200, "card_tests.rs", 284)
    branch = report(far)
    main = report(clone("card_tests.rs", 156, "card_tests.rs", 309))
    shifts = CHECK.line_shifts_from_diff(REMOVED_25_ABOVE)
    assert CHECK.new_clones(branch, main, renames={}, shifts=shifts) == [far]


def test_line_shifts_are_read_from_a_zero_context_diff_with_renames():
    diff = (
        "diff --git a/old.rs b/new.rs\nsimilarity index 90%\n"
        "rename from old.rs\nrename to new.rs\n--- a/old.rs\n+++ b/new.rs\n"
        "@@ -3 +3,2 @@\n-one\n+++two\n+three\n"
        "@@ -20,4 +21,0 @@\n-a\n-b\n-c\n-d\n"
        "diff --git a/gone.rs b/gone.rs\ndeleted file mode 100644\n"
        "--- a/gone.rs\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-x\n-y\n"
    )
    assert CHECK.line_shifts_from_diff(diff) == {
        "new.rs": [(3, 1, 3, 2), (20, 4, 21, 0)],
    }


def test_duplication_may_shrink_or_stay_but_not_grow():
    main = report(clone("a.rs", 10, "b.rs", 40), clone("c.rs", 1, "d.rs", 1))
    assert CHECK.growth(report(clone("a.rs", 10, "b.rs", 40)), main) == []
    assert CHECK.growth(main, main) == []
    more = report(clone("a.rs", 10, "b.rs", 40), clone("c.rs", 1, "d.rs", 1), clone("e.rs", 1, "f.rs", 1))
    assert CHECK.growth(more, main) == [
        "clones grew from 2 to 3",
        "duplicated lines grew from 24 to 36",
    ]


def test_a_clone_that_grows_in_place_is_growth_though_not_new():
    main = report(clone("a.rs", 10, "b.rs", 40, lines=12))
    longer = report(clone("a.rs", 10, "b.rs", 40, lines=30))
    assert CHECK.new_clones(longer, main, renames={}) == []
    assert CHECK.growth(longer, main) == ["duplicated lines grew from 12 to 30"]


def test_a_rename_changes_neither_total():
    main = report(clone("crypto/x3dh.rs", 20, "exchange/x3dh.rs", 60))
    renamed = report(clone("crypto/x25519.rs", 20, "exchange/x3dh.rs", 60))
    assert CHECK.growth(renamed, main) == []


def test_the_command_line_fails_on_a_new_clone_and_passes_without():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        main = root / "main.json"
        same = root / "same.json"
        added = root / "added.json"
        main.write_text(json.dumps(report(clone("a.rs", 10, "b.rs", 40))))
        same.write_text(json.dumps(report(clone("a.rs", 11, "b.rs", 41))))
        added.write_text(json.dumps(report(clone("a.rs", 11, "b.rs", 41), clone("c.rs", 1, "d.rs", 1))))
        names = root / "names.txt"
        names.write_text("")
        diff = root / "shifts.diff"
        diff.write_text("")
        inputs = ["--main", str(main), "--name-status", str(names), "--diff", str(diff)]
        assert CHECK.main(["--branch", str(same), *inputs]) == 0
        assert CHECK.main(["--branch", str(added), *inputs]) == 1
        grown = root / "grown.json"
        grown.write_text(json.dumps(report(clone("a.rs", 11, "b.rs", 41, lines=40))))
        assert CHECK.main(["--branch", str(grown), *inputs]) == 1
        moved = root / "moved.json"
        moved.write_text(json.dumps(report(clone("a.rs", 70, "b.rs", 40))))
        diff.write_text("diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1,0 +1,60 @@\n")
        assert CHECK.main(["--branch", str(moved), *inputs]) == 0


def test_a_missing_or_unreadable_report_fails_rather_than_passes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        good = root / "good.json"
        good.write_text(json.dumps(report()))
        broken = root / "broken.json"
        broken.write_text("{ not json")
        names = root / "names.txt"
        names.write_text("")
        diff = root / "shifts.diff"
        diff.write_text("")
        inputs = ["--name-status", str(names), "--diff", str(diff)]
        assert CHECK.main(["--branch", str(root / "absent.json"), "--main", str(good), *inputs]) == 2
        assert CHECK.main(["--branch", str(broken), "--main", str(good), *inputs]) == 2
        no_totals = root / "no_totals.json"
        no_totals.write_text(json.dumps({"duplicates": [], "statistics": {}}))
        assert CHECK.main(["--branch", str(no_totals), "--main", str(good), *inputs]) == 2
        absent_diff = ["--name-status", str(names), "--diff", str(root / "absent.diff")]
        assert CHECK.main(["--branch", str(good), "--main", str(good), *absent_diff]) == 2


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("jscpd-new-clones.test: PASS")
