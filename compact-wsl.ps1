<#
.SYNOPSIS
    Shrinks WSL2 virtual disks back down after you have freed space inside them.

.DESCRIPTION
    WSL2 virtual disks only ever grow. Deleting files inside the distro marks
    blocks free within ext4, but the .vhdx keeps its allocation until it is
    either compacted or has holes punched in it. This script does the host half:
    shuts WSL down, then compacts every distro disk it finds.

    Sparse disks are reported, not compacted. diskpart refuses them outright
    ("Virtual hard disk files must be uncompressed and unencrypted and must not
    be sparse"), and they do not need it -- WSL already returns their freed
    blocks to Windows. For those, the script shows real allocation against the
    logical size, which is the number Explorer misleadingly reports.

.PARAMETER Path
    Compact a specific .vhdx instead of auto-discovering distro disks.

.PARAMETER WhatIf
    Report what each disk is and what would happen, without shutting WSL down
    or modifying anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File compact-wsl.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File compact-wsl.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

# Explorer's "Size" column is the logical size, which for a sparse disk is
# meaningless. This is the "Size on disk" number, and the only one worth acting on.
Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);
'@ -Name 'FileSize' -Namespace 'Native' -ErrorAction SilentlyContinue

function Get-AllocatedSize {
    param([string]$File)
    $high = 0
    $low = [Native.FileSize]::GetCompressedFileSize($File, [ref]$high)
    if ($low -eq [uint32]::MaxValue -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) {
        return (Get-Item -LiteralPath $File).Length
    }
    return ([int64]$high -shl 32) -bor [int64]$low
}

function Format-Gb {
    param([int64]$Bytes)
    '{0:N2} GB' -f ($Bytes / 1GB)
}

function Test-Sparse {
    param([string]$File)
    # fsutil is the only thing that reports the sparse attribute reliably here;
    # .NET's FileAttributes does not surface it on every Windows build.
    (fsutil sparse queryflag "$File" 2>&1) -match 'is set as sparse'
}

function Get-DistroDisk {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return @() }

    Get-ChildItem $lxss | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if (-not $props.BasePath) { return }
        $vhdx = Join-Path ($props.BasePath -replace '^\\\\\?\\', '') 'ext4.vhdx'
        if (Test-Path -LiteralPath $vhdx) {
            [pscustomobject]@{ Name = $props.DistributionName; Vhdx = $vhdx }
        }
    }
}

function Invoke-Compact {
    param([string]$File)

    $script = Join-Path ([IO.Path]::GetTempPath()) "compact-wsl-$PID.txt"
    @(
        "select vdisk file=`"$File`""
        'attach vdisk readonly'
        'compact vdisk'
        'detach vdisk'
        'exit'
    ) | Set-Content -LiteralPath $script -Encoding ASCII

    try {
        $output = diskpart /s $script 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "diskpart exited $LASTEXITCODE`n$($output -join "`n")"
        }
    }
    finally {
        Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
    }
}

# --- main ---------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Needs Administrator (diskpart requires it). Re-launching elevated...' -ForegroundColor Yellow
    $argv = @('-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Path) { $argv += @('-Path', $Path) }
    if ($WhatIfPreference) { $argv += '-WhatIf' }
    Start-Process powershell -Verb RunAs -ArgumentList $argv
    return
}

$disks = if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "No such file: $Path" }
    @([pscustomobject]@{ Name = (Split-Path $Path -Leaf); Vhdx = (Resolve-Path $Path).Path })
} else {
    @(Get-DistroDisk)
}

if (-not $disks) {
    Write-Host 'No WSL distro disks found under Lxss. Pass -Path to target one directly.' -ForegroundColor Yellow
    return
}

if ($PSCmdlet.ShouldProcess('WSL', 'shut down all distros')) {
    Write-Host 'Shutting WSL down (a disk in use cannot be compacted)...'
    wsl --shutdown
    Start-Sleep -Seconds 3
}

$totalSaved = [int64]0

foreach ($disk in $disks) {
    $logical = (Get-Item -LiteralPath $disk.Vhdx).Length
    $before  = Get-AllocatedSize $disk.Vhdx

    Write-Host ''
    Write-Host "== $($disk.Name)" -ForegroundColor Cyan
    Write-Host "   $($disk.Vhdx)"
    Write-Host "   logical $(Format-Gb $logical) | on disk $(Format-Gb $before)"

    if (Test-Sparse $disk.Vhdx) {
        Write-Host '   sparse -- nothing to compact.' -ForegroundColor Green
        Write-Host '   WSL already returns freed blocks to Windows on this disk.'
        Write-Host "   The $(Format-Gb $logical) Explorer shows is the logical size, not real usage."
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($disk.Vhdx, 'compact vdisk')) { continue }

    try {
        Invoke-Compact $disk.Vhdx
    }
    catch {
        Write-Host "   compact failed: $_" -ForegroundColor Red
        continue
    }

    $after = Get-AllocatedSize $disk.Vhdx
    $saved = $before - $after
    $totalSaved += $saved
    Write-Host "   reclaimed $(Format-Gb $saved) -> now $(Format-Gb $after)" -ForegroundColor Green
}

Write-Host ''
Write-Host "Total reclaimed: $(Format-Gb $totalSaved)" -ForegroundColor Green
