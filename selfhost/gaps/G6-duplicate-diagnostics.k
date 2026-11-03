// GAP G6 (minor): one warning printed several times.
//   kairo --syntax-only --error-format=basic G6-duplicate-diagnostics.k
//   -> S025W "octal escape '\033' is only valid in byte strings" x3 at 8:14,
//      and in the self-host run every S025W in Lexer.k appeared twice.
// The pipeline dedups (logs: "duplicate diagnostics dropped"), but the
// zero-diagnostic exit should not depend on that.
fn f() {
    var t = "\033[0m"
}
