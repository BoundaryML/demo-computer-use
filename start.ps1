# Starts the Computer Use dashboard at http://127.0.0.1:8787
# Refreshes PATH so uv and baml (installed via winget) are found even in older shells.
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' + [Environment]::GetEnvironmentVariable('Path','Machine')
# Load .env (KEY=value lines). start.sh is the macOS/Linux equivalent.
$dotenv = Join-Path $PSScriptRoot '.env'
if (Test-Path $dotenv) {
    foreach ($line in Get-Content $dotenv) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $value = $Matches[2] -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
            [Environment]::SetEnvironmentVariable($Matches[1], $value, 'Process')
        }
    }
}
Set-Location $PSScriptRoot
uv run server.py @args
