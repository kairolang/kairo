// build: kairo F20-header-include-dirs-collide-as-module-roots.k -I build/llvm/include -I Lib/llvm-runtimes/llvm/include -I Lib/llvm-runtimes/lld/include   (expect exit 0; gets R018E x3)
fn main() -> i32 {
    return 0
}
