/// --- The Kairo Project ------------------- Extras/Formatter/Options.k --- ///
///
///   kfmt's knobs (README section 2) and the switches for the spec's
///   (proposed) rules.
///
///   Settings holds exactly the flags of 2.2-2.5 and 2.8; everything else is
///   fixed. Rules is the one place the spec review flips a proposed rule:
///   each switch names its rule number, and turning one off restores the
///   behaviour the rule replaced (usually "copy as written"). They are not
///   command-line flags on purpose: 2.2-2.5 and 2.8 are the only knobs.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The formatting knobs. Defaults are the spec's.
pub struct Settings {
    var use_tabs:         bool = false ///< 2.3 `--indent=tabs`
    var tab_size:         i32  = 4 ///< 2.4 `--tab-size=N`: N spaces, or N tabs under use_tabs
    var align:            bool = true ///< 2.2 off under `--no-align`
    var normalize_parens: bool = false ///< 2.5 `--normalize-parens`
    var call_width:       i32  = 80 ///< 2.8 `--call-width=N`: where a one-line call must end (4.1)
}

/// Fixed limits (not knobs: 2.1, 2.6). The call limit of 4.1 is
/// Settings::call_width (2.8).
pub fn line_width() -> i32 {
    return 100
}

pub fn max_blank_lines() -> usize {
    return 4
}

/// Grid form (4.1): more than this many items...
pub fn grid_min_items() -> usize {
    return 6
}

/// ...none wider than this...
pub fn grid_max_item() -> i32 {
    return 24
}

/// ...at most this many per row.
pub fn grid_max_cols() -> usize {
    return 8
}

/// A `case` with more than this many alternatives takes the grid form
/// (8.4).
pub fn case_grid_min() -> usize {
    return 6
}

/// More than this many cases always break a `match` expression (8.4).
pub fn match_expr_max_flat() -> usize {
    return 2
}

/// Imports with more than this many names take the grid form (5.2).
pub fn import_block_max() -> usize {
    return 6
}

/// The rules kfmt implements (README
/// 8.1-8.4, 8.11, 14.4), one switch each. `true` is the spec's rule; a
/// review can flip them here.
pub struct Rules {
    /// 3.3 / 8.2 / 8.9: control-flow conditions (`if`, `while`, `else if`,
    /// a `match` scrutinee) are laid out from the tree, so their spacing is
    /// normalized like any expression. Off: headers copied as written.
    var respace_headers: bool = true
    /// 8.1 / 8.2: an `if` with an `else` is laid out as a whole: its blocks
    /// stay one-line only while the whole chain fits on one line; otherwise
    /// every block in it is broken. Off: each one-line block decides alone,
    /// so a chain can mix `{ x }` and broken blocks.
    var if_chain_together: bool = true
    /// 8.3: `if c => a else => b` expressions stay on one line while they
    /// fit, else break before each `else`. Off: copied as written.
    var if_expr_layout: bool = true
    /// 8.3: a broken `if` expression puts each
    /// clause on its own line at the `if`'s column, keywords right-aligned
    /// so the conditions line up (`     if` / `else if` / `else`). Off: the
    /// clauses after the first go one level in.
    var if_expr_align: bool = true
    /// 8.3: `try x catch e: T => v catch => w` stays on one
    /// line while it fits, else each `catch` starts a line at the `try`'s
    /// column with the `=>` of the arms aligned. Off: copied as written.
    var try_expr_layout: bool = true
    /// 8.1: every block breaks: `{` ends the header line,
    /// the body goes one level in, `}` stands alone. Off: a block written on
    /// one line with one simple statement stays one-line while it fits.
    var blocks_always_break: bool = true
    /// 14.4: after a line of closers only (`}`, `)`, `]`,
    /// then at most a `;` or `,`) one blank line is added before the next
    /// statement-level line, unless a blank line is there already. Off:
    /// none added (14.3).
    var blank_after_closer: bool = true
    /// 8.2 / 8.4 / 8.11: a clause chains onto the `}` of the
    /// block before it: `} case B {`, `} default {` (block arms of a match
    /// statement) and `} finally {` after a statement `try`. (`} else {`
    /// and `} catch E {` always chain.) Off: each arm, and a `finally`,
    /// starts its own line.
    var chain_clauses: bool = true
    /// 8.4: a `match` expression with more than 2 cases is
    /// always broken: `match x {`, one `case` per line one level in, `}`.
    /// Off: copied as written.
    var match_expr_break: bool = true
    /// 8.4: a `case` with more than case_grid_min()
    /// alternatives lays them out as a grid aligned under the first one,
    /// no per-item width cap. Off: the patterns are copied as written.
    var case_grid: bool = true
    /// 3.5: CRLF input becomes LF. Off: a file with CRLF line ends keeps
    /// them (every line of the output ends in CRLF).
    var crlf_to_lf: bool = true
    /// 4.1: a parameter list whose aligned column leaves too little room
    /// falls back to the block form.
    var param_block_fallback: bool = true
    /// 4.1: under `--no-align` the grid form is one item per line too.
    var grid_off_without_align: bool = true
    /// 5.1: `import a::{*}` -> `import a::*`, and a single nested path
    /// `import a::{b::C}` -> `import a::b::C`.
    var import_unbrace_more: bool = true
    /// 5.2: names inside an import's braces are sorted like 5.4.
    var import_sort_items: bool = true
    /// 5.4: a blank line inside an import run is a barrier (imports above and
    /// below sort separately). Off, as Scripts/import_lint.py does: blank
    /// lines inside the run go and the whole run sorts as one.
    var import_blank_barrier: bool = false
    /// 7.5: a type body written on one line stays on one line while it fits
    /// (members joined by `; `).
    var oneline_type_bodies: bool = true
    /// 9.5 details: under `--normalize-parens`, the operand of a prefix
    /// operator that is itself a name, call or literal loses its parens too
    /// (`-(x)` -> `-x`). Off: only binary / unary operator contents.
    var parens_unary_operand: bool = true
    /// 11.2: untyped `var x = v` rows join a declaration run with an empty
    /// type column, and `=` aligns as a fourth column.
    var decl_eq_column: bool = true
    /// 11.4: consecutive lines that each end with a trailing comment align
    /// the comments one space past the longest line.
    var align_trailing_comments: bool = true
}

/// The rules in force. One instance; see Rules.
pub fn rules() -> Rules {
    return Rules{}
}
