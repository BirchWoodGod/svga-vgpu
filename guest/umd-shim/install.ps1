<#
.SYNOPSIS
  Install or remove the w7xum9.dll D3D9 UMD shim for 32-bit programs.
  PowerShell 2.0 compatible; run elevated from 64-bit PowerShell.

    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

.DESCRIPTION
  For every display adapter key whose UserModeDriverNameWow names a VMware
  SVGA driver, the first entry (the D3D9 UMD) is replaced by w7xum9.dll and
  the original list is kept in W7xOrigUserModeDriverNameWow. The shim finds
  the real driver through HKLM\SOFTWARE\win7ext\umdshim\Target9.
  New D3D9 devices pick up the change; already running programs do not.
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw 'Run this from 64-bit PowerShell.' }

$Shim = 'w7xum9.dll'
$Wow = Join-Path $env:SystemRoot 'SysWOW64'
$Hklm = [Microsoft.Win32.Registry]::LocalMachine
$Roots = @(
	'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}',
	'SYSTEM\CurrentControlSet\Control\Video'
)

# Some subkeys (e.g. Class\{...}\Properties) are SYSTEM-only even for admins.
function Open-Key($path) {
	try { $Hklm.OpenSubKey($path) } catch { $null }
}

# All adapter keys (two levels below Video\{guid}\NNNN, one below Class).
function Get-AdapterKeys {
	foreach ($root in $Roots) {
		$k = Open-Key $root
		if (-not $k) { continue }
		foreach ($a in $k.GetSubKeyNames()) {
			$sub = "$root\$a"
			$ak = Open-Key $sub
			if (-not $ak) { continue }
			if ($ak.GetValue('UserModeDriverNameWow')) { $sub }
			foreach ($b in $ak.GetSubKeyNames()) {
				$bk = Open-Key "$sub\$b"
				if ($bk -and $bk.GetValue('UserModeDriverNameWow')) { "$sub\$b" }
				if ($bk) { $bk.Close() }
			}
			$ak.Close()
		}
		$k.Close()
	}
}

$changed = 0
foreach ($path in (Get-AdapterKeys | Select-Object -Unique)) {
	$key = $Hklm.OpenSubKey($path, $true)
	$names = [string[]]$key.GetValue('UserModeDriverNameWow')
	$orig = [string[]]$key.GetValue('W7xOrigUserModeDriverNameWow')

	if ($Uninstall) {
		if ($orig) {
			$key.SetValue('UserModeDriverNameWow', $orig, [Microsoft.Win32.RegistryValueKind]::MultiString)
			$key.DeleteValue('W7xOrigUserModeDriverNameWow')
			Write-Host "restored  $path : $($orig -join ', ')"
			$changed++
		}
	} elseif ($names[0] -eq $Shim) {
		Write-Host "already   $path"
	} elseif ($names[0] -like 'vm3d*') {
		$key.SetValue('W7xOrigUserModeDriverNameWow', $names, [Microsoft.Win32.RegistryValueKind]::MultiString)
		$target = $names[0]
		$names[0] = $Shim
		$key.SetValue('UserModeDriverNameWow', $names, [Microsoft.Win32.RegistryValueKind]::MultiString)
		$cfg = $Hklm.CreateSubKey('SOFTWARE\win7ext\umdshim')
		$cfg.SetValue('Target9', $target, [Microsoft.Win32.RegistryValueKind]::String)
		$cfg.Close()
		Write-Host "shimmed   $path : $target -> $Shim"
		$changed++
	} else {
		Write-Host "skipped   $path : $($names[0]) (not a VMware SVGA driver)"
	}
	$key.Close()
}

if (-not $Uninstall) {
	$src = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $Shim
	Copy-Item -Force $src (Join-Path $Wow $Shim)
	Write-Host "copied    $Shim -> $Wow"
}
Write-Host "$changed adapter key(s) changed. Restart D3D9 programs to pick it up."
