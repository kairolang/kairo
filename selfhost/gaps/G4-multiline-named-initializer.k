// GAP G4: a named initializer split over lines.
//   kairo --syntax-only --error-format=basic G4-multiline-named-initializer.k
//   -> S054E "expected '}' to close named initializer"
// The one-line form `Chunk { base: 1, count: 0 }` parses (Spec/Docs
// structures.mdx: `Point { x: 1.0, y: 2.0 }`). Sites: Memory/ArenaList.k:359,
// Support/FileIO/VirtualFileManager.k:455, Lexer/BalanceTracker.k:51.
struct Chunk {
    var base: i32
    var count: i32
}

fn f() -> i32 {
    var c = Chunk {
        base:  1,
        count: 0
    }
    return c.base
}
