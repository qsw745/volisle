# Fresh process, no CIM/WMI handles: request safe removal of one PnP instance.
param([Parameter(Mandatory)][ValidatePattern('^(SCSI|USBSTOR)\\DISK&')][string]$InstanceId)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class VolisleEject {
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Locate_DevNodeW(out int devInst, string id, int flags);
  [DllImport("cfgmgr32.dll")] public static extern int CM_Get_Parent(out int parent, int devInst, int flags);
  [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Request_Device_EjectW(int devInst, out int veto, StringBuilder name, int len, int flags);
}
"@
$node = 0
if ([VolisleEject]::CM_Locate_DevNodeW([ref]$node, $InstanceId, 0) -ne 0) { throw 'CM_Locate_DevNode failed' }
# The disk node itself is not removable; the tray ejects its USB storage parent.
$parent = 0
if ([VolisleEject]::CM_Get_Parent([ref]$parent, $node, 0) -ne 0) { throw 'CM_Get_Parent failed' }
$node = $parent
$veto = 0; $name = New-Object System.Text.StringBuilder 260
$rc = [VolisleEject]::CM_Request_Device_EjectW($node, [ref]$veto, $name, 260, 0)
if ($rc -ne 0 -or $veto -ne 0) { throw "Windows refused safe removal: rc=$rc veto=$veto $($name.ToString())" }
'safely removed'
