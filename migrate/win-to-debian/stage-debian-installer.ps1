# Stage the Debian 13 (trixie) netboot installer onto this machine's EFI System
# Partition, so the OptiPlex 7070 Micro can boot the installer with no USB media.
#
# Run in an ELEVATED PowerShell on the 7070, while it is still on Windows:
#     Set-ExecutionPolicy -Scope Process Bypass -Force
#     .\stage-debian-installer.ps1
#
# Copies nothing outside the ESP. Reversible: delete S:\debian-installer.

$ErrorActionPreference = 'Stop'
$url  = 'http://ftp.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz'
$work = "$env:TEMP\debnetboot"

if (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell (Run as administrator)."
}

Write-Host "[1/4] Downloading netboot.tar.gz (~53 MB)..."
New-Item -ItemType Directory -Force -Path $work | Out-Null
Invoke-WebRequest -Uri $url -OutFile "$work\netboot.tar.gz" -UseBasicParsing

Write-Host "[2/4] Extracting..."
tar -xzf "$work\netboot.tar.gz" -C $work
if (-not (Test-Path "$work\debian-installer\amd64\grubx64.efi")) {
    throw "grubx64.efi missing after extract - archive may be truncated."
}

Write-Host "[3/4] Mounting the EFI System Partition as S:..."
if (Test-Path 'S:\') { Write-Host "   S: already mounted, reusing." }
else { mountvol S: /s }

Write-Host "[4/4] Copying installer to S:\debian-installer ..."
# Must sit at the ESP ROOT: grubx64.efi has /debian-installer/amd64/grub baked in
# as its prefix, so burying it under S:\EFI\ makes grub fail to find its config.
Copy-Item "$work\debian-installer" -Destination 'S:\' -Recurse -Force

Write-Host ""
Write-Host "Staged. Verify:" -ForegroundColor Green
Get-ChildItem 'S:\debian-installer\amd64\' | Select-Object Name, Length | Format-Table

Write-Host @"
NEXT - reboot and press F2 for BIOS setup, then:

  1. Boot Configuration -> Add Boot Option
        Name: Debian Installer
        File: \debian-installer\amd64\grubx64.efi   (on the internal NVMe's ESP)
  2. Secure Boot -> DISABLED
        (this grubx64.efi is not shim-signed; re-enable later if you care)
  3. Power Management -> AC Recovery -> Power On
        (a headless 24/7 box must come back after an outage by itself)
  4. Save, reboot, F12, pick "Debian Installer".

The installer runs entirely from RAM, so when it asks about partitioning it is
safe to wipe the whole disk - Windows, the ESP, and these staged files included.

BEFORE YOU WIPE: on the F12 menu, check whether "SupportAssist OS Recovery" or
"BIOSConnect" is listed. That is your only way back to a working Windows if the
install goes wrong, because you have no removable media.
"@
