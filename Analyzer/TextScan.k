/// --- The Kairo Project -------------------------- Analyzer/TextScan.k --- ///
///
///   What the server can answer from a buffer's text alone.
///
///   Folding, selection ranges and "which call is the cursor in" are about
///   brackets, not about meaning. Answering them from the text has two
///   properties the snapshot cannot offer: they are exact for the buffer as
///   it is THIS keystroke, and they work on a buffer that does not parse.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


/// A matched bracket pair, or a run of comment lines (`kind` 3).
pub struct Span {
    var open:  usize = 0  ///< offset of the opener (or the run's first byte)
    var close: usize = 0  ///< offset of the closer (or one past the run)
    var kind:  u8    = 0  ///< 0 `{}`, 1 `()`, 2 `[]`, 3 comment run
}

/// Byte classes of \p text: 0 code, 1 comment, 2 string or char literal.
/// One pass, so every scanner below skips the same things the same way.
pub fn classify(const text: string) -> [u8] {
    var cls: [u8]
    cls.resize(text.size())
    var i: usize = 0
    var n = text.size()
    while i < n {
        var c = text[i]
        if (c == 47) && ((i + 1) < n) && (text[i + 1] == 47) {
            while (i < n) && (text[i] != 10) {
                cls[i] = 1
                i += 1
            }

            continue
        }

        if (c == 47) && ((i + 1) < n) && (text[i + 1] == 42) {
            cls[i]     = 1
            cls[i + 1] = 1
            i += 2
            while i < n {
                cls[i] = 1
                if (text[i] == 47) && (text[i - 1] == 42) {
                    i += 1
                    break
                }

                i += 1
            }

            continue
        }

        if (c == 34) || (c == 39) {
            // A quote opens a literal that ends at the same quote, a
            // backslash escaping whatever follows. A `'` that is a lifetime
            // or a digit separator does not open one: it is followed by no
            // closing quote on the line, and the scan then stops at the
            // newline instead of swallowing the file.
            var q = c
            var j = i + 1
            var closed = false
            while (j < n) && (text[j] != 10 || q == 34) {
                if text[j] == 92 {
                    j += 2
                    continue
                }

                if text[j] == q {
                    closed = true
                    break
                }

                // A plain "..." string does not span lines either; a
                // triple-quoted one does, and is handled by its own quotes.
                if (text[j] == 10) && (!((i + 2) < n && text[i + 1] == 34 && text[i + 2] == 34)) {
                    break
                }

                j += 1
            }

            if closed {
                for var k: usize = i; (k <= j) && (k < n); ++k {
                    cls[k] = 2
                }

                i = j + 1
                continue
            }
        }

        i += 1
    }

    return cls
}

/// Every matched bracket pair and comment run of \p text, in order of opener.
pub fn spans(const text: string) -> [Span] {
    var out: [Span]
    var cls = classify(text)
    var stack: [usize] // indices into `out` of unclosed pairs
    var n = text.size()

    var i: usize = 0
    while i < n {
        if cls[i] == 1 {
            // A run of comment bytes, extended across lines that hold only
            // more comment: a `///` block folds as one.
            var s = i
            var e = i
            while i < n {
                while (i < n) && (cls[i] == 1) {
                    i += 1
                }

                e = i
                var j = i
                while (j < n) && ((text[j] == 32) || (text[j] == 9) || (text[j] == 10) || (text[j] == 13)) {
                    j += 1
                }

                // Only a single line break may separate the lines of a run.
                var breaks: usize = 0
                for var k: usize = i; k < j; ++k {
                    if text[k] == 10 {
                        breaks += 1
                    }
                }

                if (j < n) && (cls[j] == 1) && (breaks == 1) {
                    i = j
                    continue
                }

                break
            }

            var sp = Span{}
            sp.open  = s
            sp.close = e
            sp.kind  = 3
            out.push_back(sp)
            continue
        }

        if cls[i] == 0 {
            var c = text[i]
            if (c == 123) || (c == 40) || (c == 91) {
                var sp = Span{}
                sp.open  = i
                sp.close = usize::MAX
                sp.kind  = if c == 123 => (0 as u8) else => (if c == 40 => (1 as u8) else => (2 as u8))
                out.push_back(sp)
                stack.push_back(out.size() - 1)
            } else if (c == 125) || (c == 41) || (c == 93) {
                var want: u8 = if c == 125 => (0 as u8) else => (if c == 41 => (1 as u8) else => (2 as u8))
                // Close the nearest opener of this kind; anything opened
                // after it was never closed and is dropped, which keeps one
                // missing bracket from unbalancing the rest of the file.
                var k = stack.size()
                while k > 0 {
                    k -= 1
                    if out[stack[k]].kind == want {
                        out[stack[k]].close = i
                        while stack.size() > k {
                            stack.pop_back()
                        }

                        break
                    }
                }
            }
        }

        i += 1
    }

    return out
}

/// The call the cursor at \p at is inside: the offset of its `(`, and how
/// many top-level commas precede the cursor. `open` is usize::MAX when the
/// cursor is not inside a call's parentheses.
pub struct CallSite {
    var open:   usize = usize::MAX
    var commas: usize = 0
}

pub fn call_at(const text: string, at: usize) -> CallSite {
    var site = CallSite{}
    var cls = classify(text)
    var depth: usize = 0
    var i = at
    var steps: usize = 0
    while (i > 0) && (steps < 8192) {
        i -= 1
        steps += 1
        if cls[i] != 0 {
            continue
        }

        var c = text[i]
        if (c == 41) || (c == 93) || (c == 125) {
            depth += 1
        } else if c == 40 {
            if depth == 0 {
                site.open = i
                return site
            }

            depth -= 1
        } else if (c == 91) || (c == 123) {
            if depth == 0 {
                return site // inside an index or a block, not an argument list
            }

            depth -= 1
        } else if (c == 44) && (depth == 0) {
            site.commas += 1
        } else if (c == 59) && (depth == 0) {
            return site
        }
    }

    return site
}
