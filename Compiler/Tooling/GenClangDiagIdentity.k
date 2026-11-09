ffi "c++" import "clang/Basic/DiagnosticIDs.h"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "Native/Types.hh"

pub fn main() -> i32 {
    var flags = clang::DiagnosticIDs::getDiagnosticFlags()
    llvm::sort(flags)

    for flag in flags {
        // Synthetic catch-all entries returned by Clang.
        // TODO(STD-STRING): Stage 1.5 drops the std::string use.
        var flag_text = kairo::std::from_std_string<string>(flag)
        if flag_text == r"-W" || flag_text == r"-Wno-" {
            continue
        }

        // One code per warning group, not one code per polarity.
        if flag.starts_with(r"-Wno-") {
            continue
        }

        // Store the canonical group spelling without "-W".
        llvm::outs() << flag.substr(2) << "\n"
    }

    return 0
}
