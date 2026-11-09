// RUN: %kfmt --no-align --stdout %s | diff -u %S/Expected/no_align.k -
// RUN: %kfmt --no-align --check %S/Expected/no_align.k
//
// Rule 2.2: --no-align turns off every alignment rule: no columns in runs,
// parameters in the block form, the grid in one item per line (proposed).

fn create_session(config: *SessionConfig, diag: *DiagnosticsEngine, sources: *SourceManager, opts: *Options) -> *Session {
    var short = 1;
    var much_longer = 2;
    var names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"];
    return &null;
}
