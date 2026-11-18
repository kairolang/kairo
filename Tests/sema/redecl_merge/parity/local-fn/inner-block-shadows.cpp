// ORACLE MAPPING: see same-frame.cpp.
// Clean by default; -Wshadow reports the shadow, which is what Kairo shows
// in the --print-sema trace rather than as a diagnostic.
void outer() {
    auto helper = []() { };
    if (true) {
        auto helper = []() { };
    }
}
