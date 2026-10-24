// build: kairo F19-fsanitize-never-reaches-clang.k -fsanitize=address -o f31   (expect an ASan-instrumented binary; gets U002E). kcc -fsanitize=address -c on this file exits 0 with no __asan_* symbols in the object.
fn main() -> i32 {
    var a: [i32; 4] = [1, 2, 3, 4]
    return a[0] - 1
}
