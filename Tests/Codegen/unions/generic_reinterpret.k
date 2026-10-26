// Tests/Codegen/unions/generic_reinterpret.k
// build: kairo generic_reinterpret.k   (expect exit 0)
// Generic head, `template <class A, class B> union Reinterpret`.

union <A, B> Reinterpret {
    var a: A
    var b: B
}

fn main() -> i32 {
    var r: Reinterpret<f32, u32>
    r.a = 1.0f32
    if r.b == 0x3F800000 { return 0 }
    return 1
}