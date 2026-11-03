// GAP or USER QUESTION G5: `self` in a closure capture list.
//   kairo --syntax-only --error-format=basic G5-capture-self.k
//   -> S047E "expected capture name or '*' in capture list"
// Spec/Docs closures.mdx shows `|a, *b|`, `|*|`, `|const *x|` but never
// `self`. Stage 0 captures it by value (a pointer). Sites:
// Location/SourceManager.k:222, Driver/CompilerInstance.k:4362.
class A {
    var n: i32
    fn f(self) {
        var c = fn () |self| { }
    }
}
