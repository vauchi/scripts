// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

// Custom MD013 replacement: line-length with backtick-path exemption.
//
// Flags lines over 80 characters UNLESS the over-limit portion is
// entirely inside backtick spans. This lets inline paths like
// `core/vauchi-app/src/ui/app_engine/mod.rs` push a line past 80
// without triggering a warning.
//
// Also skips: fenced code blocks, tables, HTML comments, link lines.
//
// Usage:
//   markdownlint --disable MD013 \
//     -r scripts/markdownlint-rule-line-length.js .

"use strict";

const LINE_LENGTH = 80;

/**
 * Strip all backtick-enclosed spans from a line and return the
 * result. Nested/escaped backticks are not expected in our docs.
 */
function stripBacktickSpans(line) {
  return line.replace(/`[^`]*`/g, "");
}

module.exports = {
  names: ["line-length-backtick-exempt"],
  description:
    "Line length (backtick spans exempt from over-limit portion)",
  tags: ["custom"],
  parser: "none",
  function: (params, onError) => {
    const limit =
      (params.config && params.config.line_length) || LINE_LENGTH;

    let inCodeBlock = false;

    params.lines.forEach((line, index) => {
      // Track fenced code blocks (``` or ~~~).
      if (/^\s*(`{3,}|~{3,})/.test(line)) {
        inCodeBlock = !inCodeBlock;
        return;
      }

      // Skip lines inside code blocks.
      if (inCodeBlock) {
        return;
      }

      // Skip lines within limit.
      if (line.length <= limit) {
        return;
      }

      // Skip headings — long titles can't be wrapped.
      if (/^\s*#{1,6}\s/.test(line)) {
        return;
      }

      // Skip table rows — paths in tables are common.
      if (/^\s*\|/.test(line)) {
        return;
      }

      // Strip backtick spans and re-check.
      const stripped = stripBacktickSpans(line);
      if (stripped.length <= limit) {
        return;
      }

      // Skip lines containing URLs (can't be wrapped).
      if (/https?:\/\//.test(line)) {
        return;
      }

      // Skip pure-link lines and reference definitions.
      if (/^\s*\[.*\]\(.*\)\s*$/.test(line)) {
        return;
      }
      if (/^\s*\[.*\]:\s/.test(line)) {
        return;
      }

      // Skip HTML comments (SPDX headers).
      if (/^\s*<!--.*-->\s*$/.test(line)) {
        return;
      }

      onError({
        lineNumber: index + 1,
        detail:
          `Expected: ${limit}; Actual: ${line.length}` +
          ` (${stripped.length} without backticks)`,
        range: [limit + 1, line.length - limit],
      });
    });
  },
};
