# PanLink Lite local v2.0.0 (hardened) - read-only verification of downloaded files.
# No network, no credential access, no file deletion. The optional report is a new file.
# -CompareSourceMd5 compares the 32-digit MD5 supplied by the source API, when present.
# A mismatch is an investigation signal, not permission to overwrite or delete data.
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [switch]$Hash,
    [switch]$CompareSourceMd5,
    [string]$Report
)
$ErrorActionPreference = 'Stop'
$m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($m.version -ne 2 -or -not $m.root -or $null -eq $m.files) { throw 'Invalid v2 manifest' }
$root = [IO.Path]::GetFullPath([string]$m.root).TrimEnd('\','/')
if ($root -notmatch '^[A-Za-z]:\\.+') { throw 'Expected a Windows absolute download directory' }
$prefix = $root + '\'
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point' }
}
# Check every ancestor, not only the final download root.
$cursor = [IO.Path]::GetPathRoot($root)
Assert-NoReparse $cursor
foreach ($part in ($root.Substring($cursor.Length) -split '[\\/]')) {
    if ($part) { $cursor = Join-Path $cursor $part; Assert-NoReparse $cursor }
}
$rows = @(foreach ($f in $m.files) {
    $relative = [string]$f.relative
    $expected = [long]$f.bytes
    $result = 'Missing'; $actual = $null; $sha = $null; $md5 = $null
    try {
        if ($expected -lt 0 -or [string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.?([\\/]|$)' -or $relative -match '[:*?"<>|]') { throw 'Unsafe relative path' }
        $path = [IO.Path]::GetFullPath([IO.Path]::Combine($root,$relative))
        if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path outside root' }
        $cursor = $root
        foreach ($part in ($relative -split '[\\/]')) {
            if ([string]::IsNullOrWhiteSpace($part) -or $part -match '[. ]$') { throw 'Unsafe path component' }
            $cursor = Join-Path $cursor $part
            if (Test-Path -LiteralPath $cursor) { Assert-NoReparse $cursor }
        }
        if (Test-Path -LiteralPath ($path+'.aria2')) { $result = 'IncompleteControlFile' }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            # Deny concurrent writers while computing hash. Recheck length within the handle.
            $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $actual = [long]$stream.Length
                if ($actual -ne $expected) { $result = 'SizeMismatch' }
                else {
                    $result = 'SizeMatch'
                    if ($Hash) { $sha = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant(); $stream.Position = 0 }
                    if ($CompareSourceMd5 -and ([string]$f.sourceMd5 -match '^[a-fA-F0-9]{32}$')) {
                        $md5 = (Get-FileHash -InputStream $stream -Algorithm MD5).Hash.ToLowerInvariant()
                        if ($md5 -eq ([string]$f.sourceMd5).ToLowerInvariant()) { $result = 'HashMatch' } else { $result = 'HashMismatch' }
                    }
                }
            } finally { $stream.Dispose() }
            if (Test-Path -LiteralPath ($path+'.aria2')) { $result = 'IncompleteControlFile' }
        }
    } catch { $result = 'UnsafeOrUnreadable' }
    [pscustomobject]@{ key=$f.key; relative=$relative; queueStatus=$f.status; expectedBytes=$expected; actualBytes=$actual; result=$result; localSHA256=$sha; localMD5=$md5 }
})
if ($Report) {
    $out = [IO.Path]::GetFullPath($Report)
    if (Test-Path -LiteralPath $out) { throw 'Report already exists; choose a new filename' }
    $reportData = [ordered]@{ version=2; root=[string]$m.root; account=$m.account; verifiedAt=[DateTime]::UtcNow.ToString('o'); files=$rows }
    # CreateNew protects against accidental overwrite.
    $stream = [IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false)); try { $writer.Write(($reportData | ConvertTo-Json -Depth 8)) } finally { $writer.Dispose() } } finally { $stream.Dispose() }
}
$rows
Write-Host '--- Summary ---'
$rows | Group-Object result | Select-Object Name,Count | Format-Table -AutoSize | Out-Host
Write-Host 'SizeMatch is not remote hash equality. HashMatch compares the supplied source MD5 only. Report reflects verification time.'
