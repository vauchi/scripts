// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

// Custom MD013 replacement: line-length with backtick-path and link exemption.
//
// Flags lines over 80 characters UNLESS the over-limit portion is
// entirely inside backtick spans or inline Markdown links. This lets
// inline paths like `core/vauchi-app/src/ui/app_engine/mod.rs` and
// cross-reference links like [`adr-021`](../../decisions/adr-021-rust-for-core-library.md)
// push a line past 80 without triggering a warning.
//
// Also skips: fenced code blocks, tables, headings, reference links, single-line
// HTML comments.
//
// Auto-fixes long lines by wrapping at the last word boundary before the limit.
// Lines inside multi-line HTML comments are continued with five spaces so the
// comment stays well-formed.
//
// Usage:
//   markdownlint --disable MD013 \
//     -r scripts/markdownlint-rule-line-length.js .

"use strict";

const LINE_LENGTH = 80;

/**
 * Strip inline Markdown links and backtick spans from a line, returning both
 * the stripped text and a map from stripped character indices to original
 * character indices.
 */
function stripBacktickSpansAndLinks(line) {
  const strippedChars = [];
  const originalIndices = [];

  let i = 0;
  while (i < line.length) {
    // Inline Markdown link: [text](url)
    if (line[i] === "[") {
      const closeBracket = line.indexOf("]", i + 1);
      if (
        closeBracket !== -1 &&
        line[closeBracket + 1] === "(" &&
        line.indexOf(")", closeBracket + 2) !== -1
      ) {
        const openParen = closeBracket + 1;
        const closeParen = line.indexOf(")", openParen + 1);
        // Keep the link text.
        for (let j = i + 1; j < closeBracket; j++) {
          strippedChars.push(line[j]);
          originalIndices.push(j);
        }
        i = closeParen + 1;
        continue;
      }
    }

    // Backtick span.
    if (line[i] === "`") {
      const endTick = line.indexOf("`", i + 1);
      if (endTick !== -1) {
        i = endTick + 1;
        continue;
      }
    }

    strippedChars.push(line[i]);
    originalIndices.push(i);
    i++;
  }

  return {
    text: strippedChars.join(""),
    originalIndices,
  };
}

/**
 * Compute a fixInfo object that wraps `line` at the last word boundary before
 * `limit`. Returns null if no safe wrap point is found.
 */
function computeFix(line, limit, isInHtmlComment) {
  const leadingMatch = line.match(/^(\s*)/);
  const leadingIndent = leadingMatch ? leadingMatch[1] : "";

  // For HTML comments (single-line or multi-line), continue with five spaces
  // so the comment formatting remains valid. For other blocks, reuse the
  // leading indentation.
  const isHtmlCommentLine = line.includes("<!--") || isInHtmlComment;
  const continuationIndent = isHtmlCommentLine ? "     " : leadingIndent;

  const { text: stripped, originalIndices } = stripBacktickSpansAndLinks(line);
  if (stripped.length <= limit) {
    return null;
  }

  // Find the last space in the stripped text before the limit.
  let wrapStrippedIndex = -1;
  for (let j = limit - 1; j >= 0; j--) {
    if (stripped[j] === " ") {
      wrapStrippedIndex = j;
      break;
    }
  }
  if (wrapStrippedIndex <= 0) {
    // No safe word boundary before the limit.
    return null;
  }

  const originalIndex = originalIndices[wrapStrippedIndex];
  if (originalIndex === undefined) {
    return null;
  }

  // Replace the single space at the wrap point with a newline + indentation.
  return {
    editColumn: originalIndex + 1,
    deleteCount: 1,
    insertText: "\n" + continuationIndent,
  };
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
    let inHtmlComment = false;

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

      // Track multi-line HTML comments.
      if (inHtmlComment) {
        if (/-->/.test(line)) {
          inHtmlComment = false;
        }
      } else if (/<!--/.test(line) && !/-->/.test(line)) {
        inHtmlComment = true;
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

      // Strip backtick spans and inline links, then re-check.
      const stripped = stripBacktickSpansAndLinks(line).text;
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

      const fixInfo = computeFix(line, limit, inHtmlComment);

      onError({
        lineNumber: index + 1,
        detail:
          `Expected: ${limit}; Actual: ${line.length}` +
          ` (${stripped.length} without backticks/links)`,
        range: [limit + 1, line.length - limit],
        fixInfo,
      });
    });
  },
};
