$ErrorActionPreference = "Stop"

$PrinterName = "PharmLabels"
$DriverName  = "DYMO LabelWriter 330-USB"
$PortName    = "\\PCM92\PharmLabels"
$ActiveDir   = "$env:windir\System32\spool\drivers\x64\3"
$RepoRoot    = "$env:windir\System32\DriverStore\FileRepository"
$DymoGood    = "C:\DymoGood"
$Files       = @("UNIDRV.DLL","UNIDRVUI.DLL","UNIRES.DLL")

$LogDir = "C:\AVA\Support"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $LogDir "DYMO_PrintFix_$Stamp.txt"

function Log([string]$Text) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text" | Tee-Object -FilePath $Log -Append
}

function FileVer([string]$Path) {
    $v = (Get-Item $Path).VersionInfo.FileVersion
    if ($v -match '(\d+\.\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return [version]"0.0.0.0"
}

function SameHash([string]$A,[string]$B) {
    if (!(Test-Path $A) -or !(Test-Path $B)) { return $false }
    return ((Get-FileHash $A -Algorithm SHA256).Hash -eq (Get-FileHash $B -Algorithm SHA256).Hash)
}

Log "=== DYMO / UNIDRV quick repair started ==="

$os = Get-CimInstance Win32_OperatingSystem
Log "OS: $($os.Caption)  Build $($os.BuildNumber)"

if ($os.Caption -notlike "*Windows 10*") {
    Log "STOP: This script is intentionally limited to Windows 10."
    Write-Host "This script is for the Windows 10 ServerX repair only." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 2
}

$candidates = Get-ChildItem $RepoRoot -Directory -Filter "ntprint.inf_amd64_*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $amd64 = Join-Path $_.FullName "Amd64"
        $complete = $true
        foreach ($f in $Files) {
            if (-not (Test-Path (Join-Path $amd64 $f))) { $complete = $false }
        }
        if ($complete) {
            $u = Join-Path $amd64 "UNIDRV.DLL"
            $ver = FileVer $u
            if ($ver.Major -eq 10 -and $ver.Minor -eq 0 -and $ver.Build -eq 19041) {
                [PSCustomObject]@{ Path=$amd64; Version=$ver }
            }
        }
    } | Sort-Object Version -Descending

$source = $candidates | Select-Object -First 1
if (-not $source) {
    Log "STOP: No complete Windows 10 19041-family ntprint.inf package found."
    Write-Host "No suitable local ntprint.inf source was found. No files were changed." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 3
}

$Src = $source.Path
Log "Selected local ntprint source: $Src"
Log "Source UNIDRV version: $($source.Version)"

foreach ($f in $Files) {
    $sig = Get-AuthenticodeSignature (Join-Path $Src $f)
    Log "$f source signature: $($sig.Status)"
    if ($sig.Status -ne "Valid") {
        Log "STOP: Signature validation failed for $f."
        Write-Host "Signature validation failed for $f. No repair was performed." -ForegroundColor Red
        Read-Host "Press Enter to close"
        exit 4
    }
}

$needsRepair = $false
foreach ($f in $Files) {
    $s = Join-Path $Src $f
    $d = Join-Path $ActiveDir $f
    $match = SameHash $s $d
    $activeVer = if (Test-Path $d) { (Get-Item $d).VersionInfo.FileVersion } else { "<missing>" }
    Log "$f active version: $activeVer ; matches local ntprint source: $match"
    if (-not $match) { $needsRepair = $true }
}

if ($needsRepair) {
    Write-Host "UNIDRV mismatch detected. Repairing from ServerX's own Windows DriverStore..." -ForegroundColor Yellow
    Log "UNIDRV mismatch detected; beginning repair."

    Stop-Service Spooler -Force -ErrorAction SilentlyContinue
    Get-Process splwow64,PrintIsolationHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $Backup = Join-Path "C:\PrintFixBackup" $Stamp
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    Log "Backup folder: $Backup"

    foreach ($f in $Files) {
        $d = Join-Path $ActiveDir $f
        if (Test-Path $d) {
            Copy-Item $d (Join-Path $Backup $f) -Force
            Remove-Item $d -Force
        }
    }

    foreach ($f in $Files) {
        Copy-Item (Join-Path $Src $f) (Join-Path $ActiveDir $f) -Force
    }

    Get-ChildItem $ActiveDir -Filter "*.BUD" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    foreach ($f in $Files) {
        $match = SameHash (Join-Path $Src $f) (Join-Path $ActiveDir $f)
        Log "$f post-copy hash match: $match"
        if (-not $match) {
            Start-Service Spooler -ErrorAction SilentlyContinue
            Write-Host "Repair verification failed for $f. Stop here." -ForegroundColor Red
            Read-Host "Press Enter to close"
            exit 5
        }
    }

    Start-Service Spooler
    Start-Sleep -Seconds 2
    Log "Spooler restarted."
} else {
    Log "UNIDRV files already match the local Windows 10 ntprint package."
    if ((Get-Service Spooler).Status -ne "Running") { Start-Service Spooler }
}

$driver = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
if (-not $driver) {
    Log "DYMO printer driver is not registered."
    if (Test-Path $DymoGood) {
        Get-ChildItem $DymoGood -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            & pnputil.exe /add-driver $_.FullName /install | Out-File $Log -Append
        }
    }
    Add-PrinterDriver -Name $DriverName
    Log "Registered printer driver: $DriverName"
}

if (-not (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $PortName
    Log "Created Local Port: $PortName"
}

$p = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
if (-not $p) {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
    Log "Created printer queue: $PrinterName"
} elseif ($p.DriverName -ne $DriverName -or $p.PortName -ne $PortName) {
    Set-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
    Log "Corrected printer queue driver/port."
}

$p = Get-Printer -Name $PrinterName
Write-Host ""
Write-Host "=== FINAL STATUS ===" -ForegroundColor Green
$p | Format-List Name,DriverName,PortName,PrinterStatus
Write-Host "Log: $Log"
Write-Host ""
Write-Host "If AmeriVet prints without an error, the repair is complete." -ForegroundColor Green
Read-Host "Press Enter to close"
