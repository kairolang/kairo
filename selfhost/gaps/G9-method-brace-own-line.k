// GAP G9: a METHOD whose body `{` stands on its own line.
//   kairo --syntax-only --error-format=basic G9-method-brace-own-line.k
//   -> S048E "expected a field, method, or nested type in the type body"
//      at the `{` (14:5 and 18:5 below)
// The same layout parses for a free function (k below), and for a method
// whose `{` ends the line of its return type (h), so a newline before the
// body brace is accepted in one position and rejected in the other.
// Self-host sites (first error of their file, 2026-11-03 at ce799d3f):
// Resolution/ImportProbe.k:649 (and :708, :1454, :1503, :1514, :1525 in
// the same file, a 50-diagnostic cascade), Location/SourceManager.k:639.
class C {
    fn f(self, x: i32)
        -> i32
    {
        return x
    }
    fn g(self, x: i32) -> i32
    {
        return x
    }
    fn h(self, x: i32)
        -> i32 {
        return x
    }
}
fn k(x: i32)
    -> i32
{
    return x
}
