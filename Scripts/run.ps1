# PowerShell wrapper
# Usage: .\make.ps1 <args...>
$py = $null
foreach ($p in @("python", "python3", "py")) {
    if (Get-Command $p -ErrorAction SilentlyContinue) {
        $py = $p; break
    }
}
if ($null -eq $py) {
    Write-Error "Python not found on PATH"
    exit 1
}
& $py "$PSScriptRoot\Scripts\build.py" @args
exit $LASTEXITCODE
