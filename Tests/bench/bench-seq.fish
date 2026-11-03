#!/usr/bin/env fish
# Runs the benchmarks one after another, each built and timed on its own
# through bench-run.fish, instead of all of them interleaved.
#
#   ./bench-seq.fish [--smoke] [runs]    runs defaults to 5
cd (dirname (status filename))
for b in nbody btree fannkuch gsort gen errpath alloc interp closures dispatch wideint fmt spectral slices nullable scopes
    echo "== $b"
    ./bench-run.fish $argv $b
end
