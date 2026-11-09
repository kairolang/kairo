// RUN: %kfmt --indent=tabs --stdout %s | diff -u %S/Expected/tabs.k -
// RUN: %kfmt --indent=tabs --check %S/Expected/tabs.k
//
// Rule 2.3: --indent=tabs writes each level as one tab; the padding that
// aligns columns stays spaces, after the tabs.

fn create_session(config:  *SessionConfig,
                  diag:    *DiagnosticsEngine,
                  sources: *SourceManager,
                  opts:    *Options) -> *Session {
	if x {
		var a   = 1
		var bbb = 2
	}

	return &null
}
