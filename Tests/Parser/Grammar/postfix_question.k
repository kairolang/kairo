// `?` is postfix: it asks whether a nullable holds a value. It composes with
// prefix `!` as `!(mem?)`, and does not collide with `??`, `?.` or `?->`.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn Test() {
    var mem = alloc()
    if !mem? { return }
    if mem? { use(mem) }
    var a = mem ?? fallback
    var b = mem?.field
    var c = mem?->field
}
