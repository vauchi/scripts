// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

// VDC01 — no machine-local absolute paths in documentation.
//
// Flags /home/<user>/…, /Users/<user>/…, and C:\Users\… anywhere in a
// markdown file (code blocks included: a pasted log leaks the same
// username and breaks for the same readers). Use workspace-root
// relative paths (core/vauchi-app/src/…) or file-relative links.
// Page: _private/docs/lint-errors/vdc01-absolute-paths.md
//
// Usage:
//   markdownlint -r scripts/ci-templates/markdownlint-rule-no-abs-paths.js .

"use strict";

const ABS_PATH = /(\/home\/[a-z_][a-z0-9_-]*\/|\/Users\/[A-Za-z0-9._-]+\/|C:\\Users\\)/;

module.exports = {
  names: ["no-abs-paths"],
  description:
    "VDC01: machine-local absolute path — fix: use a workspace-root-relative path",
  tags: ["custom"],
  parser: "none",
  function: (params, onError) => {
    params.lines.forEach((line, index) => {
      const match = ABS_PATH.exec(line);
      if (!match) {
        return;
      }
      onError({
        lineNumber: index + 1,
        detail:
          `found "${match[1]}…" — machine-local paths leak usernames and` +
          " are wrong on every other machine" +
          " [_private/docs/lint-errors/vdc01-absolute-paths.md]",
        range: [match.index + 1, match[1].length],
      });
    });
  },
};
