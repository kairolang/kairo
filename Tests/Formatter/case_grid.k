// RUN: %kfmt --stdout %s | diff -u %S/Expected/case_grid.k -
// RUN: %kfmt --check %S/Expected/case_grid.k
//
// Rule 8.4 (decided 2026-11-08): a `case` with more than 6
// alternatives lays them out as a grid: the first row after `case `, the
// others aligned under it, each column padded to its widest pattern, as
// many columns as fit in 100 columns (no per-item width cap), source order
// row by row, only the last row short, ` {` (or ` =>`) after the last
// pattern. Six or fewer are copied as written. The example is
// `is_binary_operator` in Compiler/Token/TokenKind.k.

pub fn is_binary_operator(kind: TokenKind) -> bool {
    match kind {
        case TokenKind::KwIn, TokenKind::OpLessLessEqual,
             TokenKind::KwAs, TokenKind::OpGreaterGreaterEqual,
             TokenKind::KwAnd, TokenKind::OpAtEqual,
             TokenKind::OpQuestionArrowStar, TokenKind::OpQuestionQuestion,
             TokenKind::OpQuestionDotStar {
            return true
        }
        case TokenKind::KwOr, TokenKind::KwXor { return true }
        default { return false }
    }
}

fn short(c: u8) -> i32 {
    return match c { case 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27 => 1 case 0 => 0 default => 2 };
}
