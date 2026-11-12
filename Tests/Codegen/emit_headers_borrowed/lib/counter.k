// The helpers scope.k's public template calls: module-visible (`prot`), so
// counter's own header leaves them out by its root rule.
thread depth: usize = 0

prot inline fn push() -> usize {
    var d = depth
    depth = d + 1
    return d
}

prot inline fn pop(d: usize) {
    depth = d
}

pub fn current() -> usize { return depth }
