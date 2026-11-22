param([Parameter(Mandatory=$true)][string]$Path)
$stream = [IO.File]::OpenRead($Path)
try { $sha = [Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','').ToLowerInvariant() }
finally { $stream.Dispose() }
