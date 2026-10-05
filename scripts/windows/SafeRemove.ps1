# "Safely Remove Hardware" for the USB disk holding the volume labelled $Label.
# Uses CM_Request_Device_Eject like the Windows tray; refuses (veto) if in use.
param([Parameter(Mandatory)][string]$Label)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class VolisleEject {
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Locate_DevNodeW(out int devInst, string id, int flags);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Request_Device_EjectW(int devInst, out int veto, StringBuilder name, int len, int flags);
}
"@
$volume = Get-Volume -FileSystemLabel $Label
$disk = $volume | Get-Partition | Get-Disk
if ($disk.BusType -ne 'USB') { throw "Refusing: disk bus is $($disk.BusType), not USB" }
# \\?\scsi#disk&ven_x#6&abc&0&000000#{guid}  ->  SCSI\DISK&VEN_X\6&ABC&0&000000
$instance = ($disk.Path -replace '^\\\\\?\\', '' -replace '#\{[^}]+\}$', '').Replace('#', '\').ToUpperInvariant()
$pnp = Get-PnpDevice -Class DiskDrive -PresentOnly | Where-Object { $_.InstanceId -eq $instance }
if (@($pnp).Count -ne 1) { throw "Cannot uniquely identify the USB disk: $instance" }
Write-VolumeCache -DriveLetter $volume.DriveLetter
$node = 0
if ([VolisleEject]::CM_Locate_DevNodeW([ref]$node, $pnp.InstanceId, 0) -ne 0) { throw 'CM_Locate_DevNode failed' }
$veto = 0; $name = New-Object System.Text.StringBuilder 260
$rc = [VolisleEject]::CM_Request_Device_EjectW($node, [ref]$veto, $name, 260, 0)
if ($rc -ne 0 -or $veto -ne 0) { throw "Windows refused safe removal: rc=$rc veto=$veto $($name.ToString())" }
"safely removed $($disk.FriendlyName)"
