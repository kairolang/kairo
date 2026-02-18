# Load xmake environment
. $env:USERPROFILE\.xmake\profile.ps1

# setup xmake for release or debug mode
xmake f -m release

# build and run kairo-tests
xmake -v
