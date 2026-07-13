ffi "c++" import "clang/Basic/DiagnosticIDs.h";
ffi "c++" import "llvm/ADT/STLExtras.h";
ffi "c++" import "llvm/Support/raw_ostream.h";

fn main() -> i32 {
    var flags = clang::DiagnosticIDs::getDiagnosticFlags();
    llvm::sort(flags);

    for flag in flags {
        // Synthetic catch-all entries returned by Clang.
        if (flag == r"-W") || (flag == r"-Wno-") {
            continue;
        }

        // One code per warning group, not one code per polarity.
        if flag.starts_with(r"-Wno-") {
            continue;
        }

        // Store the canonical group spelling without "-W".
        llvm::outs() << flag.substr(2) << r"\n";
    }

    return 0;
}