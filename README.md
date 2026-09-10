# DYMO LabelWriter 330 Turbo — Fixing `0x00000006 / The Handle Is Invalid` After a Windows Update

**Authors: Rocky & BigMike**

> **Field-tested case study, not an official Microsoft or DYMO fix.** This procedure modifies Windows print-driver files. Back up first, use the affected computer's own Microsoft DriverStore as the repair source, and do not copy system DLLs from random websites or from a different Windows version.

## What happened

This documents a real-world failure involving an older **DYMO LabelWriter 330 Turbo USB** connected to a Windows 11 workstation and shared to a Windows 10 computer.

The printer had worked normally for years, but after a Windows update on the Windows 11 print host, one Windows 10 client could no longer connect to the shared printer. Windows repeatedly returned:

> **Windows cannot connect to the printer.**  
> **Operation failed with error 0x00000006.**

or:

> **Unable to install printer.**  
> **The handle is invalid.**

The printer itself was good, the USB connection was good, and another Windows 10 workstation could still print to the same Windows 11 host.

The actual failure was ultimately isolated to the **Windows 10 client's legacy V3 UNIDRV print stack**.

The key discovery was an active:

```text
UNIDRV.DLL  10.0.26100.9444
```

inside:

```text
C:\Windows\System32\spool\DRIVERS\x64\3
```

on a **Windows 10 22H2** client. Build `26100` belongs to the Windows 11 24H2 family, while Windows 10 22H2 uses build `19045`.

Replacing the active UNIDRV components with the matching copies from that same Windows 10 machine's local Microsoft `ntprint.inf` DriverStore restored the ability to create the DYMO queue.

## Tested environment

- Printer: **DYMO LabelWriter 330 Turbo USB**
- Host: Windows 11 workstation
- Shared printer path in this case: `\\PCM92\PharmLabels`
- Affected client: **Windows 10 Pro 22H2**
- Affected client build: **19045.2251**
- DYMO driver: **DYMO LabelWriter 330-USB**
- Legacy Type 3 DYMO package observed: **8.5.0.542**
- Another Windows 10 workstation could still print normally to the same shared printer

The exact computer and share names are examples. Substitute your own.

## Symptoms

The affected Windows 10 client showed several of these symptoms:

- Connecting to the shared printer failed with `0x00000006`.
- Windows displayed **The handle is invalid**.
- Rebooting the client did not help.
- Restarting the Print Spooler did not help.
- Deleting and reconnecting the printer did not help.
- Creating a Local Port for the UNC printer path did not help.
- Clearing the print queue did not help.
- Deleting the Client Side Rendering Print Provider cache did not help.
- Reinstalling the legacy DYMO driver did not initially help.
- Rolling back the newly installed host update did not repair the already-broken Windows 10 client.

The diagnostic breakthrough was proving that the failure could be reproduced **without the network printer at all**.

## 1. Prove whether the failure is local or network-related

After installing/registering the DYMO driver, create a test queue on the local `FILE:` port:

```powershell
Add-Printer -Name "DYMO_TEST" `
  -DriverName "DYMO LabelWriter 330-USB" `
  -PortName "FILE:"
```

If this fails with:

```text
HRESULT 0x80070006
```

then the problem is local to the Windows client's print subsystem or driver stack. This test never contacts the Windows 11 print host, so it is a fast way to stop chasing SMB, permissions, RPC, Point-and-Print, or printer-share settings.

If the test works, remove it:

```powershell
Remove-Printer -Name "DYMO_TEST"
```

## 2. Check the PrintService event log

Open elevated PowerShell:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Admin' -MaxEvents 50 |
Where-Object {$_.Id -eq 808} |
Select-Object -First 10 TimeCreated,Message |
Format-List
```

In this case the log repeatedly showed:

```text
The print spooler failed to load a plug-in module
C:\Windows\System32\spool\DRIVERS\x64\3\UNIDRVUI.DLL,
error code 0x7F
```

Windows error `0x7F` is `ERROR_PROC_NOT_FOUND` — **The specified procedure could not be found.** That strongly suggested incompatible or mismatched common V3 UNIDRV components.

## 3. Inspect the active UNIDRV components

```powershell
Get-Item `
"C:\Windows\System32\spool\drivers\x64\3\UNIDRV.DLL", `
"C:\Windows\System32\spool\drivers\x64\3\UNIDRVUI.DLL", `
"C:\Windows\System32\spool\drivers\x64\3\UNIRES.DLL" |
Select-Object Name,
@{Name="Version";Expression={$_.VersionInfo.FileVersion}},
Length,
LastWriteTime |
Format-Table -AutoSize
```

The glaring anomaly in this case was:

```text
UNIDRV.DLL  10.0.26100.9444
```

on the Windows 10 22H2 client.

## 4. Find the correct Microsoft copy already on the affected PC

**Do not download these DLLs from a DLL-download website.** Use the affected computer's own Windows DriverStore.

```powershell
Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
-Filter UNIDRV.DLL -Recurse -ErrorAction SilentlyContinue |
Where-Object {$_.FullName -like "*ntprint.inf_amd64*"} |
Select-Object FullName,
@{Name="Version";Expression={$_.VersionInfo.FileVersion}} |
Format-List
```

In our machine, the correct local Windows 10-family source was under a path similar to:

```text
C:\Windows\System32\DriverStore\FileRepository\
ntprint.inf_amd64_77cea3a0d7cf1851\Amd64
```

**Your suffix will almost certainly be different.**

The selected local `ntprint.inf` package should contain:

```text
UNIDRV.DLL
UNIDRVUI.DLL
UNIRES.DLL
```

Verify Microsoft signatures before using the files:

```powershell
Get-AuthenticodeSignature "$src\UNIDRV.DLL"
Get-AuthenticodeSignature "$src\UNIDRVUI.DLL"
Get-AuthenticodeSignature "$src\UNIRES.DLL"
```

The signature status should be `Valid`.

## 5. Back up and repair the active V3 UNIDRV files

Open an elevated Command Prompt and stop the print subsystem:

```cmd
net stop spooler
taskkill /F /IM splwow64.exe
taskkill /F /IM PrintIsolationHost.exe
```

It is harmless if either process is not running.

Create a backup:

```cmd
mkdir C:\PrintFixBackup
copy "C:\Windows\System32\spool\DRIVERS\x64\3\UNIDRV.DLL" C:\PrintFixBackup\
copy "C:\Windows\System32\spool\DRIVERS\x64\3\UNIDRVUI.DLL" C:\PrintFixBackup\
copy "C:\Windows\System32\spool\DRIVERS\x64\3\UNIRES.DLL" C:\PrintFixBackup\
```

Now replace the active copies with the matching files from the affected machine's own `ntprint.inf` package. Change the source path to the one found on your computer:

```cmd
copy /Y "C:\Windows\System32\DriverStore\FileRepository\ntprint.inf_amd64_XXXXXXXXXXXX\Amd64\UNIDRV.DLL" "C:\Windows\System32\spool\DRIVERS\x64\3\UNIDRV.DLL"

copy /Y "C:\Windows\System32\DriverStore\FileRepository\ntprint.inf_amd64_XXXXXXXXXXXX\Amd64\UNIDRVUI.DLL" "C:\Windows\System32\spool\DRIVERS\x64\3\UNIDRVUI.DLL"

copy /Y "C:\Windows\System32\DriverStore\FileRepository\ntprint.inf_amd64_XXXXXXXXXXXX\Amd64\UNIRES.DLL" "C:\Windows\System32\spool\DRIVERS\x64\3\UNIRES.DLL"
```

Delete compiled Unidrv `.BUD` cache files so Windows can regenerate them:

```cmd
del /F /Q "C:\Windows\System32\spool\DRIVERS\x64\3\*.BUD"
```

If no `.BUD` files exist, that is not an error.

## 6. Verify with SHA-256 hashes, not only displayed version strings

This mattered in our case because some files retained confusing older embedded version strings even though they had been correctly copied.

With the spooler still stopped:

```powershell
$src="C:\Windows\System32\DriverStore\FileRepository\ntprint.inf_amd64_XXXXXXXXXXXX\Amd64"
$dst="C:\Windows\System32\spool\drivers\x64\3"
$files="UNIDRV.DLL","UNIDRVUI.DLL","UNIRES.DLL"

$files | ForEach-Object {
    $s=(Get-FileHash "$src\$_").Hash
    $d=(Get-FileHash "$dst\$_").Hash
    [PSCustomObject]@{
        File=$_
        Match=($s -eq $d)
    }
} | Format-Table -AutoSize
```

You want:

```text
File           Match
----           -----
UNIDRV.DLL      True
UNIDRVUI.DLL    True
UNIRES.DLL      True
```

Those hashes prove the destination files are byte-for-byte identical to the selected local Microsoft source package.

## 7. Restart the spooler and repeat the local test

```powershell
Start-Service Spooler
```

Then:

```powershell
Add-Printer -Name "DYMO_TEST" `
  -DriverName "DYMO LabelWriter 330-USB" `
  -PortName "FILE:"
```

In this case the exact same test failed with `0x80070006` before the UNIDRV repair and **worked immediately after the repair**.

Remove the test queue:

```powershell
Remove-Printer -Name "DYMO_TEST"
```

## 8. Create the real shared printer using a Local Port

A Local Port can avoid some Point-and-Print complications with very old Type 3 drivers.

```powershell
Add-PrinterPort -Name "\\PCM92\PharmLabels"
```

Then:

```powershell
Add-Printer -Name "PharmLabels" `
  -DriverName "DYMO LabelWriter 330-USB" `
  -PortName "\\PCM92\PharmLabels"
```

Verify:

```powershell
Get-Printer -Name "PharmLabels" |
Format-List Name,DriverName,PortName,PrinterStatus
```

Our repaired system reported:

```text
Name          : PharmLabels
DriverName    : DYMO LabelWriter 330-USB
PortName      : \\PCM92\PharmLabels
PrinterStatus : Normal
```

The DYMO Printing Preferences dialog also opened normally, allowing the correct label size to be selected.

## What actually fixed it

Several common fixes **did not** solve this case:

```text
Rebooting
Restarting the spooler
Deleting/recreating the network printer
Creating a UNC Local Port
Clearing the spool queue
Deleting Client Side Rendering Print Provider state
Reinstalling the legacy DYMO software
Rolling back the latest host update
```

The behavior changed only after repairing the Windows 10 client's **common V3 UNIDRV components** from its own local Microsoft `ntprint.inf` DriverStore.

Before the repair:

```text
Add-Printer using FILE: -> 0x80070006
```

After the repair:

```text
Add-Printer using FILE: -> success
Shared DYMO queue creation -> success
Application print submission -> no error
```

## About Windows/.NET updates

This failure appeared immediately after Microsoft updates on the Windows 11 print host, and similar DYMO/shared-printer failures had historically appeared around Windows/.NET servicing on this network.

However, this troubleshooting session did **not** prove that .NET itself directly modified the bad DLL. What we proved was:

1. The problem began around a Windows servicing event.
2. A Windows 10 client contained a Windows 11-family `UNIDRV.DLL` in its active V3 print-driver directory.
3. Event Viewer logged `UNIDRVUI.DLL` load failures with error `0x7F`.
4. The local DYMO `FILE:` test failed with `0x80070006`.
5. Repairing the active UNIDRV set from the same Windows 10 computer's Microsoft DriverStore restored the local test and allowed the real DYMO queue to be created.

It is therefore reasonable to suspect a Windows servicing / legacy shared-printer interaction, but it would be inaccurate to state that a particular .NET update was conclusively the root cause without additional evidence.

## Two-minute future diagnostic

If the same failure returns:

```powershell
# 1. Can the old DYMO V3 driver create a local queue?
Add-Printer -Name "DYMO_TEST" `
  -DriverName "DYMO LabelWriter 330-USB" `
  -PortName "FILE:"

# 2. If that fails with 0x80070006, inspect Event 808:
Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Admin' -MaxEvents 50 |
Where-Object {$_.Id -eq 808} |
Select-Object -First 10 TimeCreated,Message |
Format-List

# 3. Inspect the active renderer:
(Get-Item "C:\Windows\System32\spool\drivers\x64\3\UNIDRV.DLL").VersionInfo.FileVersion
```

If a Windows 10 machine suddenly has a `26100.x` `UNIDRV.DLL` in its active V3 print folder, investigate that immediately.

## Included helper scripts

This repository also contains the exact helper scripts created for our environment:

- [`Fix_DYMO_UNIDRV.ps1`](Fix_DYMO_UNIDRV.ps1)
- [`Run_DYMO_PrintFix_Admin.bat`](Run_DYMO_PrintFix_Admin.bat)

**Important:** the PowerShell script is deliberately specific to our Windows 10 setup. It uses the printer name `PharmLabels`, driver `DYMO LabelWriter 330-USB`, share `\\PCM92\PharmLabels`, and local paths used during this repair. Review and edit those variables before using it elsewhere.

## Safety notes

- Back up before replacing print-driver DLLs.
- Use the affected computer's own local Microsoft DriverStore as the source.
- Verify digital signatures and hashes.
- Do not download system DLLs from third-party DLL sites.
- Do not assume the exact `ntprint.inf_amd64_...` folder suffix will match another computer.
- Do not blindly apply Windows 10 files to Windows 11 or Windows Server.
- This procedure is most relevant to old **V3 / Unidrv-based** printer drivers such as legacy DYMO LabelWriter software.
- If you are not comfortable repairing Windows printer-driver components, stop after the diagnostic steps and use them to guide a qualified administrator.

## Microsoft references

- [Microsoft Learn — Unidrv Components](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/unidrv-components)
- [Microsoft Learn — System Error Codes 0–499](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-)
- [Microsoft Learn — Windows version/build targeting information](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/inf-manufacturer-section)

## Final result

After repairing the Windows 10 V3 UNIDRV layer, the DYMO test queue could be created locally, the real `PharmLabels` queue could be created using the local UNC port, and the application was able to submit a label without reporting an error.

For anyone maintaining an old DYMO LabelWriter in a mixed Windows 10 / Windows 11 environment, **Event ID 808 plus a local `FILE:` test is a fast way to distinguish a network-sharing problem from a broken local V3 print stack.**

---

**Rocky & BigMike**