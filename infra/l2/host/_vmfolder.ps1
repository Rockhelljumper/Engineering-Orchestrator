# VM folder checks for step 02, its undo and verify-host, and the no-link, no-overwrite
# file writes the elevated steps use. Dot-sourced by _common.ps1; it changes nothing on
# its own.
#
# The VM, its disks and the installer ISO live in the chain
#     C:\  >  C:\Hyper-V ($EO.VmParent)  >  C:\Hyper-V\eo-l2 ($EO.Root)  >  iso ($EO.IsoDir)
# C:\ lets every authenticated user create folders and gives them Modify (delete
# included) on what inherits from it. So a C:\Hyper-V that inherits from C:\, or one a
# standard user made, can be renamed or replaced by that user, who could then plant
# a VM folder with their own configuration and disks for Hyper-V to open, or turn a
# folder in the chain into a junction so an elevated delete lands somewhere else
# (measured on RH-DT-M3: Remove-Item through a junction deletes the redirected target,
# e.g. C:\ProgramData\eo-l2, which holds the 01b/01c records).
#
# The rules, enforced here:
#   - no folder from C:\ down to the iso folder is a link (reparse point: junction,
#     symbolic link, mount point), checked level by level, because a path string read
#     through a junction looks the same as the real one;
#   - C:\Hyper-V is owned by Administrators, SYSTEM or TrustedInstaller and no other
#     account has a write-class right on it (see Test-EoPathFacts). Then no standard
#     user can rename, replace or write into it, and every check below stays true until
#     an administrator changes it: that is what closes the check/use window for
#     unprivileged users. Other folders in C:\Hyper-V (other VMs) are left alone;
#   - C:\Hyper-V\eo-l2 and its iso folder: owner Administrators or SYSTEM, inheritance
#     off, Administrators and SYSTEM only, plus read access at most for this VM's own
#     account (Hyper-V may add it);
#   - the disks, the ISO and the VM configuration: no link, owner Administrators,
#     SYSTEM or this VM's account, access for Administrators, SYSTEM and this VM's
#     account only. "This VM's account" is NT VIRTUAL MACHINE\<id of VM eo-l2>, built
#     from the VM's id (ConvertTo-EoVmSid); before the VM exists no VM account is
#     accepted, and another VM's account or the Virtual Machines group never is;
#   - C:\Hyper-V\eo-l2 holds only what step 02 and Hyper-V put there (Test-EoVmTree).
#
# Test-* functions are pure: they take plain facts and return a list of problems
# (empty when all is well), so tests/selftest.ps1 can drive them without elevation
# or Hyper-V. Get-* functions read the facts; New-/Remove-/Assert-/Write- act or throw.

$EoSidAdmins = 'S-1-5-32-544'
$EoSidSystem = 'S-1-5-18'
$EoSidUsers = 'S-1-5-32-545'
$EoSidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$EoSidCreatorOwner = 'S-1-3-0'

# Admin-only scratch folders the elevated steps make directly under ProgramData and
# delete again: eo-l2-gpg-<id> (the gpg home of an elevated signature check),
# eo-l2-sums-<id> (02's copy of SHA256SUMS, its signature and the key) and
# eo-l2-selftest-<id> (the self-test). Never C:\ProgramData\eo-l2 itself.
$EoScratchPattern = '\Aeo-l2-(gpg|sums|selftest)-[0-9a-f]{32}\z'

# Rights that let an account change a folder or file, add to it, delete it or what is
# in it, or change its permissions or owner: WriteData/CreateFiles 0x2,
# AppendData/CreateDirectories 0x4, WriteExtendedAttributes 0x10,
# DeleteSubdirectoriesAndFiles 0x40, WriteAttributes 0x100, Delete 0x10000,
# ChangePermissions 0x40000, TakeOwnership 0x80000, MAXIMUM_ALLOWED 0x2000000,
# GENERIC_ALL 0x10000000, GENERIC_WRITE 0x40000000 (generic bits appear in inherit-only
# entries such as CREATOR OWNER).
$EoWriteRights = [int64](0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x2000000 -bor 0x10000000 -bor 0x40000000)

# The SID of NT VIRTUAL MACHINE\<VmId>, the account the VM's worker process runs as:
# 'S-1-5-83-1-' and the VM id's 16 bytes (Guid.ToByteArray) read as four little-endian
# UInt32, joined by '-'. '' for no id (the VM does not exist yet). Pure.
function ConvertTo-EoVmSid([string]$VmId) {
    if (-not $VmId) { return '' }
    $g = [guid]::Empty
    if (-not [guid]::TryParse($VmId, [ref]$g)) { throw "VM id '$VmId' is not a GUID" }
    $b = $g.ToByteArray()
    $parts = @(0, 1, 2, 3 | ForEach-Object { [System.BitConverter]::ToUInt32($b, $_ * 4) })
    return 'S-1-5-83-1-' + ($parts -join '-')
}

# Every folder from the drive root down to $Path, $Path included, in that order:
# 'C:\Hyper-V\eo-l2\iso' gives C:\, C:\Hyper-V, C:\Hyper-V\eo-l2, C:\Hyper-V\eo-l2\iso.
# Pure (string work only).
function Get-EoAncestorPaths([string]$Path) {
    $out = New-Object System.Collections.Generic.List[string]
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $out.Add($root)
    $cur = $root
    foreach ($part in @($full.Substring($root.Length) -split '\\' | Where-Object { $_ })) {
        $cur = if ($cur.EndsWith('\')) { "$cur$part" } else { "$cur\$part" }
        $out.Add($cur)
    }
    return $out
}

# The innermost .NET exception of an error record (PowerShell wraps exceptions from
# method calls in a MethodInvocationException).
function Get-EoInnerException($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    return $e
}

# The attributes of $Path itself (a link is not followed for the last component), or
# $null when nothing is there. A dangling link is reported, not taken as absent.
function Get-EoEntryAttributes([string]$Path) {
    try { return [System.IO.File]::GetAttributes($Path) }
    catch {
        $e = Get-EoInnerException $_
        if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) { return $null }
        throw
    }
}

# Owner, inheritance and entries of a FileSystemSecurity (from Get-Acl, or the one
# New-EoDirSecurity builds) as plain facts: @{ Owner; Protected; Aces }. Rights is the
# raw access mask (generic bits included) as an Int64; GENERIC_READ (0x80000000) reads
# as a negative Int32 first, which no write-class bit matches.
function ConvertTo-EoSecurityFacts($Security) {
    $sid = [System.Security.Principal.SecurityIdentifier]
    $o = $Security.GetOwner($sid)
    $aces = @($Security.GetAccessRules($true, $true, $sid) | ForEach-Object {
            @{ Sid = "$($_.IdentityReference.Value)"; Allow = ("$($_.AccessControlType)" -eq 'Allow'); Rights = [int64][int]$_.FileSystemRights
                Inherited = [bool]$_.IsInherited; InheritOnly = ((([int]$_.PropagationFlags) -band 2) -ne 0) } })
    return @{ Owner = $(if ($o) { "$($o.Value)" } else { $null }); Protected = [bool]$Security.AreAccessRulesProtected; Aces = $aces }
}

# Plain facts about one path: @{ Path; Exists; Reparse; Container; Owner (SID);
# Protected (inheritance off); Aces = @( @{ Sid; Allow; Rights (int64); Inherited;
# InheritOnly } ) }. The ACL is not read for a link (it would be the target's) or
# with -NoAcl.
function Get-EoPathFacts([string]$Path, [switch]$NoAcl) {
    $attr = Get-EoEntryAttributes $Path
    $f = @{ Path = $Path; Exists = ($null -ne $attr); Reparse = $false; Container = $false; Owner = $null; Protected = $false; Aces = @() }
    if ($null -eq $attr) { return $f }
    $a = [int]$attr
    $f.Reparse = (($a -band 0x400) -ne 0)
    $f.Container = (($a -band 0x10) -ne 0)
    if ($NoAcl -or $f.Reparse) { return $f }
    $acl = Get-Acl -LiteralPath $Path
    $s = ConvertTo-EoSecurityFacts $acl
    foreach ($k in 'Owner', 'Protected', 'Aces') { $f[$k] = $s[$k] }
    return $f
}

# Problems with one path's facts (from Get-EoPathFacts or a test). Deny entries only
# take access away and are not counted. $VmSid is this VM's account (ConvertTo-EoVmSid
# of VM eo-l2's id), or '' before the VM exists. $Kind:
#   parent  C:\Hyper-V as found. Owner Administrators, SYSTEM or TrustedInstaller.
#           Inheritance may be on, but no Allow entry, inherited or explicit, may give
#           a write-class right ($EoWriteRights) to any account other than those three;
#           read-only entries for other accounts are accepted (Users and Explorer
#           traverse it; other VMs may live there). CREATOR OWNER is accepted only as an
#           inherit-only entry: it never applies to C:\Hyper-V itself, and stands only
#           for whoever creates a child, which this rule limits to those three accounts.
#           With -New (02 just created it): owner Administrators, inheritance off, and
#           only Administrators, SYSTEM and Users (read only), nothing else.
#   root    C:\Hyper-V\eo-l2 and its iso folder (and the self-test's and the steps'
#           scratch folders): owner Administrators or SYSTEM (Administrators with
#           -New), inheritance off, Allow entries for Administrators and SYSTEM, and,
#           without -New, $VmSid with no write-class right; nothing else.
#   vm      the disks, the ISO and the VM configuration: owner Administrators, SYSTEM or
#           $VmSid (the worker process may create its runtime files), inheritance may be
#           on, Allow entries for Administrators, SYSTEM and $VmSid only.
# Another VM's account and the Virtual Machines group (S-1-5-83-0) count as "any other".
# -Container says whether a folder (or a file) is expected.
function Test-EoPathFacts($Facts, [string]$Kind, [switch]$Container, [switch]$New, [string]$VmSid = '') {
    $p = New-Object System.Collections.Generic.List[string]
    if ($Kind -notin @('parent', 'root', 'vm')) { throw "Test-EoPathFacts: unknown kind '$Kind'" }
    $path = "$($Facts.Path)"
    if (-not $Facts.Exists) { $p.Add("$path does not exist"); return $p }
    if ($Facts.Reparse) { $p.Add("$path is a link (reparse point: junction, symbolic link or mount point)"); return $p }
    if ([bool]$Facts.Container -ne [bool]$Container) { $p.Add("$path is $(if ($Facts.Container) { 'a folder' } else { 'a file' }), want $(if ($Container) { 'a folder' } else { 'a file' })") }
    $owners = if ($New) { @($EoSidAdmins) } elseif ($Kind -eq 'parent') { @($EoSidAdmins, $EoSidSystem, $EoSidTrustedInstaller) } else { @($EoSidAdmins, $EoSidSystem) }
    $vmOwned = ($Kind -eq 'vm' -and $VmSid -and "$($Facts.Owner)" -eq $VmSid)
    if ("$($Facts.Owner)" -notin $owners -and -not $vmOwned) { $p.Add("$path is owned by $($Facts.Owner), want $(if ($New) { 'Administrators' } elseif ($Kind -eq 'parent') { 'Administrators, SYSTEM or TrustedInstaller' } elseif ($Kind -eq 'vm') { 'Administrators, SYSTEM or this VM''s account' } else { 'Administrators or SYSTEM' })") }
    if (($Kind -eq 'root' -or $New) -and -not $Facts.Protected) { $p.Add("$path inherits permissions from its parent") }
    $allows = @(@($Facts.Aces) | Where-Object { $_ -and $_.Allow })
    if (-not $allows.Count) { $p.Add("$path has no access entries (an empty or null ACL)") }
    $admin = if ($Kind -eq 'parent' -and -not $New) { @($EoSidAdmins, $EoSidSystem, $EoSidTrustedInstaller) } else { @($EoSidAdmins, $EoSidSystem) }
    foreach ($a in $allows) {
        $sid = "$($a.Sid)"
        if ($sid -in $admin) { continue }
        $rights = [int64]$a.Rights
        $write = (($rights -band $EoWriteRights) -ne 0)
        $thisVm = ($VmSid -and $sid -eq $VmSid)
        $what = '{0} (rights 0x{1:X}{2}{3})' -f $sid, $rights, $(if ($a.Inherited) { ', inherited' } else { '' }), $(if ($a.InheritOnly) { ', inherit-only' } else { '' })
        if ($Kind -eq 'parent' -and $New) {
            if ($sid -eq $EoSidUsers -and -not $write) { continue }
            $p.Add("$path grants $what; a new C:\Hyper-V may grant only Administrators, SYSTEM and Users (read)")
        } elseif ($Kind -eq 'parent') {
            if (-not $write) { continue }
            if ($sid -eq $EoSidCreatorOwner -and $a.InheritOnly) { continue }
            $p.Add("$path grants a write-class right to $what; only Administrators, SYSTEM and TrustedInstaller may have one")
        } elseif ($Kind -eq 'vm') {
            if ($thisVm) { continue }
            $p.Add("$path grants access to $what; only Administrators, SYSTEM and this VM's own account may have access")
        } else {
            if ($thisVm -and -not $write -and -not $New) { continue }
            $p.Add("$path grants access to $what; only Administrators and SYSTEM may have access (this VM's own account read only)")
        }
    }
    return $p
}

# Problems with a chain of folder facts (Get-EoPathFacts -NoAcl, drive root first): a
# level that exists must be a folder and not a link. Missing levels are not problems
# here (the deeper ones cannot exist either). Pure.
function Test-EoChainFacts($Facts) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($Facts)) {
        if (-not $f.Exists) { continue }
        if ($f.Reparse) { $p.Add("$($f.Path) is a link (reparse point); a path through it would reach another folder") }
        elseif (-not $f.Container) { $p.Add("$($f.Path) is a file, want a folder") }
    }
    return $p
}

# Problems with the folders from the drive root down to $Path ($Path included). Read-only.
function Get-EoChainProblems([string]$Path) {
    @(Test-EoChainFacts @(Get-EoAncestorPaths $Path | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))
}

# Throws unless no folder from the drive root down to $Path is a link (or a file).
function Assert-EoNoLinkChain([string]$Path, [string]$What) {
    $p = @(Get-EoChainProblems $Path)
    if ($p.Count) { throw "Refusing to use $What ($Path): $($p -join '; '). Nothing was written there; investigate who changed it." }
}

# Every entry below $Root, read without following links: a folder that is a link is
# listed (Reparse) but not entered. @{ Rel (path below $Root); Full; Container;
# Reparse; Unreadable }. A folder that cannot be listed (access denied, such as a
# running VM's runtime folder) throws, or with -Tolerant is listed with Unreadable set
# and not entered. $Root itself must be listable.
function Get-EoTreeEntries([string]$Root, [switch]$Tolerant) {
    $out = New-Object System.Collections.Generic.List[object]
    $base = $Root.TrimEnd('\')
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ Rel = ''; Full = $base; Container = $true; Reparse = $false; Unreadable = $false })
    while ($stack.Count) {
        $dir = $stack.Pop()
        $names = $null
        try { $names = @([System.IO.Directory]::GetFileSystemEntries($dir.Full)) }
        catch {
            if ($Tolerant -and $dir.Rel -and (Get-EoInnerException $_) -is [System.UnauthorizedAccessException]) { $dir.Unreadable = $true; continue }
            throw
        }
        foreach ($full in $names) {
            $a = [int][System.IO.File]::GetAttributes($full)
            $e = [pscustomobject]@{ Rel = $full.Substring($base.Length).TrimStart('\'); Full = $full; Container = (($a -band 0x10) -ne 0); Reparse = (($a -band 0x400) -ne 0); Unreadable = $false }
            $out.Add($e)
            if ($e.Container -and -not $e.Reparse) { $stack.Push($e) }
        }
    }
    return $out
}

# The names of the entries directly in a folder (links included, not followed).
function Get-EoDirNames([string]$Path) {
    @([System.IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
}

# The Hyper-V folders New-VM -Path $EO.Root -Name $EO.VmName may create under
# $EO.Root\$EO.VmName: the configuration ("Virtual Machines": <id>.vmcx, .vmgs, .vmrs,
# and a <id> folder while the VM runs) and checkpoints ("Snapshots", disabled here but
# Hyper-V may create the folder). Anything below these two is accepted (still no link).
$EoVmConfigDirs = @('Virtual Machines', 'Snapshots')

# Problems with what C:\Hyper-V\eo-l2 holds (entries from Get-EoTreeEntries), against
# what step 02 and Hyper-V create there:
#   eo-l2-system.vhdx, eo-l2-anchor.vhdx       files
#   eo-l2.vmid                                 file: the VM's id, written by 02
#   iso                                        folder, holding only *.iso files
#   eo-l2                                      folder (the VM's, from New-VM -Path)
#   eo-l2\Virtual Machines, eo-l2\Snapshots    folders, with anything below them
# Fewer entries are fine (02 stopped part way, or undo deleted part of it). Any link
# anywhere fails, and so does a folder that could not be listed, except, with
# -AllowUnreadable, one below eo-l2\Virtual Machines (a running VM's runtime folder;
# undo-02 checks again, without it, once the VM is off and removed). Pure.
function Test-EoVmTree($Entries, [string]$VmName = $EO.VmName, [switch]$AllowUnreadable, [string]$Root = $EO.Root) {
    $p = New-Object System.Collections.Generic.List[string]
    $sysVhd = Split-Path -Leaf $EO.SystemVhd; $ancVhd = Split-Path -Leaf $EO.AnchorVhd; $iso = Split-Path -Leaf $EO.IsoDir; $idFile = Split-Path -Leaf $EO.VmIdFile
    foreach ($e in @($Entries)) {
        $rel = "$($e.Rel)"
        if ($e.Reparse) { $p.Add("$rel is a link (reparse point) inside $Root"); continue }
        $parts = @($rel -split '\\')
        $dir = [bool]$e.Container
        $ok = $false
        if ($parts.Count -eq 1) {
            $ok = (($rel -ieq $sysVhd -or $rel -ieq $ancVhd -or $rel -ieq $idFile) -and -not $dir) -or (($rel -ieq $iso -or $rel -ieq $VmName) -and $dir)
        } elseif ($parts[0] -ieq $iso) {
            $ok = ($parts.Count -eq 2 -and -not $dir -and $parts[1] -like '*.iso')
        } elseif ($parts[0] -ieq $VmName) {
            $ok = ($parts[1] -iin $EoVmConfigDirs) -and ($parts.Count -gt 2 -or $dir)
        }
        if (-not $ok) { $p.Add("$rel ($(if ($dir) { 'folder' } else { 'file' })) is not something step 02 or Hyper-V creates in $Root"); continue }
        if ((Get-EoProp $e 'Unreadable') -eq $true) {
            $runtime = ($parts.Count -ge 3 -and $parts[0] -ieq $VmName -and $parts[1] -ieq 'Virtual Machines')
            if (-not ($AllowUnreadable -and $runtime)) { $p.Add("$rel could not be listed (access denied), so what it holds is unknown") }
        }
    }
    return $p
}

# Problems that make a path unfit for Remove-EoVerifiedTree: it must be a full, normal
# path (no '~') at least two folders below a drive root; it must not be, hold or sit inside the
# 01b/01c record folder ($EO.GuardDir), the evidence folder, ProgramData, Windows or
# the user profile (whose folders the user can change). The one exception: an
# admin-only scratch folder directly under ProgramData whose name matches
# $EoScratchPattern (eo-l2-gpg-, eo-l2-sums- or eo-l2-selftest- and 32 hex digits),
# or a folder inside one. There is no parameter to skip any of this. Pure (string
# work only).
function Test-EoDeletableRoot([string]$Root) {
    $p = New-Object System.Collections.Generic.List[string]
    if (-not $Root -or -not [System.IO.Path]::IsPathRooted($Root) -or $Root -notmatch '\A[A-Za-z]:\\') { $p.Add("'$Root' is not a full path on a drive"); return $p }
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -ine $Root.TrimEnd('\')) { $p.Add("'$Root' is not in normal form (it resolves to '$full')") }
    # An 8.3 short name (C:\PROGRA~3) would hide which folder this is from the checks below.
    if ($full.Contains('~')) { $p.Add("'$Root' contains '~' (a short 8.3 name would hide the real folder)") }
    if (@($full.Substring([System.IO.Path]::GetPathRoot($full).Length) -split '\\' | Where-Object { $_ }).Count -lt 2) { $p.Add("'$Root' is less than two folders below its drive root") }
    $pd = "$env:ProgramData".TrimEnd('\')
    $underPd = if ($pd -and $full.StartsWith("$pd\", [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($pd.Length + 1) } else { '' }
    $scratch = $underPd -and (@($underPd -split '\\')[0] -cmatch $EoScratchPattern)
    foreach ($keep in @($EO.GuardDir, $EO.Evidence, $env:ProgramData, $env:windir, $env:USERPROFILE)) {
        if (-not $keep) { continue }
        $k = $keep.TrimEnd('\')
        if ($full -ieq $k -or $k.StartsWith("$full\", [System.StringComparison]::OrdinalIgnoreCase)) { $p.Add("'$Root' is or holds '$k'") }
        elseif ($full.StartsWith("$k\", [System.StringComparison]::OrdinalIgnoreCase) -and -not ($scratch -and $k -ieq $pd)) { $p.Add("'$Root' is inside '$k'") }
    }
    return $p
}

# The security 02 gives a folder it creates: owner Administrators, inheritance off,
# Administrators and SYSTEM full control (this folder, subfolders and files), and for
# the parent (C:\Hyper-V) also Users read and execute, so Hyper-V, Explorer and other
# VMs' folders can be reached. Nothing else.
function New-EoDirSecurity([switch]$Parent) {
    # PowerShell 7 keeps the ACL types in System.IO.FileSystem.AccessControl, which may
    # not be loaded yet; Windows PowerShell 5.1 has them in mscorlib (the load fails there).
    try { $null = [System.Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl') } catch { }
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $adm = New-Object System.Security.Principal.SecurityIdentifier $EoSidAdmins
    $sys = New-Object System.Security.Principal.SecurityIdentifier $EoSidSystem
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $sec.SetOwner($adm)
    $sec.SetAccessRuleProtection($true, $false)
    $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $adm, ([System.Security.AccessControl.FileSystemRights]::FullControl), $inh, $none, $allow))
    $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $sys, ([System.Security.AccessControl.FileSystemRights]::FullControl), $inh, $none, $allow))
    if ($Parent) {
        $usr = New-Object System.Security.Principal.SecurityIdentifier $EoSidUsers
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $usr, ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute), $inh, $none, $allow))
    }
    return $sec
}

# The call that creates a folder with its ACL in one step on this edition:
# 'DirectoryInfo' (Windows PowerShell 5.1, .NET Framework: DirectoryInfo.Create
# (DirectorySecurity)), 'Extensions' (PowerShell 7: FileSystemAclExtensions.Create),
# or '' when neither is found. Read-only.
function Get-EoSecureCreateMethod {
    try { $null = [System.Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl') } catch { }
    $null = New-EoDirSecurity
    if ([System.IO.DirectoryInfo].GetMethod('Create', [type[]]@([System.Security.AccessControl.DirectorySecurity]))) { return 'DirectoryInfo' }
    if (Get-EoAclExtensionsType) { return 'Extensions' }
    return ''
}

function Get-EoAclExtensionsType {
    foreach ($asm in @([System.Security.AccessControl.DirectorySecurity].Assembly) + @([AppDomain]::CurrentDomain.GetAssemblies())) {
        $t = $null
        try { $t = $asm.GetType('System.IO.FileSystemAclExtensions', $false) } catch { }
        if ($t -and $t.GetMethod('Create', [type[]]@([System.IO.DirectoryInfo], [System.Security.AccessControl.DirectorySecurity]))) { return $t }
    }
    return $null
}

# Creates one folder (its parent must exist and not be a link) with New-EoDirSecurity
# applied in the create call itself, so it never exists with an inherited ACL. Refuses
# a path that already exists. The create calls succeed silently when the folder
# appeared in between, so the caller must read it back with Assert-EoNewDir before
# using it; an unprivileged account that won that race owns the folder, which
# Assert-EoNewDir refuses. When this edition has no such call it throws (fail closed):
# creating first and setting the ACL after would leave a window in which a standard
# user can open a handle that keeps its access.
function New-EoSecureDir([string]$Path, [switch]$Parent) {
    if ($null -ne (Get-EoEntryAttributes $Path)) { throw "$Path already exists; refusing to reuse it." }
    # The create calls would also make missing parents; only one level is made here.
    $up = Get-EoPathFacts ([System.IO.Path]::GetDirectoryName($Path)) -NoAcl
    if (-not $up.Exists -or $up.Reparse -or -not $up.Container) { throw "Refusing to create $Path`: its parent $($up.Path) is missing, a link or not a folder." }
    # Get-Acl loads the ACL types on PowerShell 7 (and shows the parent can be read).
    $null = Get-Acl -LiteralPath ([System.IO.Path]::GetDirectoryName($Path))
    $how = Get-EoSecureCreateMethod
    $sec = New-EoDirSecurity -Parent:$Parent
    $di = New-Object System.IO.DirectoryInfo $Path
    if ($how -eq 'DirectoryInfo') {
        $di.Create($sec)
    } elseif ($how -eq 'Extensions') {
        $ext = Get-EoAclExtensionsType
        $ext::Create($di, $sec)
    } else {
        throw "Refusing to create $Path`: this PowerShell ($($PSVersionTable.PSVersion)) offers no call that creates a folder with its ACL in one step. Nothing was created."
    }
    Write-Host "created $Path with its ACL in the create call ($how)"
}

# Throws unless $Path (just made by New-EoSecureDir) is a folder, not a link, owned by
# Administrators, with exactly the planned protected ACL, and empty; and no folder
# above it is a link.
function Assert-EoNewDir([string]$Path, [switch]$Parent) {
    $p = @(Get-EoChainProblems $Path)
    if (-not $p.Count) {
        $p = @(Test-EoPathFacts (Get-EoPathFacts $Path) $(if ($Parent) { 'parent' } else { 'root' }) -Container -New)
        if (-not $p.Count) {
            $names = @(Get-EoDirNames $Path)
            if ($names.Count) { $p += "$Path is not empty right after it was created: $($names -join ', ')" }
        }
    }
    if ($p.Count) { throw "Refusing to use $Path, which this step just created: $($p -join '; '). Someone else may have made or changed it; investigate before going on." }
    Write-Host "checked $Path`: not a link, owner Administrators, inheritance off, the planned entries only, empty"
}

# Makes an admin-only scratch folder $env:ProgramData\eo-l2-<Kind>-<random> (Kind:
# gpg, sums or selftest) with New-EoSecureDir, checks it, and returns its path. Needs
# elevation. Remove it with Remove-EoVerifiedTree, which accepts these names.
function New-EoScratchDir([string]$Kind) {
    if ($Kind -cnotin @('gpg', 'sums', 'selftest')) { throw "New-EoScratchDir: unknown kind '$Kind'" }
    $pd = "$env:ProgramData".TrimEnd('\')
    if (-not $pd) { throw 'ProgramData is not set' }
    Assert-EoNoLinkChain $pd 'ProgramData'
    $path = Join-Path $pd ("eo-l2-$Kind-" + [guid]::NewGuid().ToString('N'))
    New-EoSecureDir $path
    Assert-EoNewDir $path
    return $path
}

# Writes $Text to the new file $Path in the folder $Dir, never through a link and never
# over anything: $Path must sit directly in $Dir, no folder from the drive root down to
# $Dir may be a link, nothing may exist at $Path yet, and the file is opened with
# FileMode.CreateNew (which fails if a file or link appeared there in between). UTF-8,
# with a byte order mark only with -Bom (what Set-Content -Encoding UTF8 writes on
# Windows PowerShell 5.1; PowerShell 7 writes none).
function Write-EoNewFile([string]$Path, [string]$Text, [string]$Dir, [switch]$Bom) {
    if ("$([System.IO.Path]::GetDirectoryName($Path))".TrimEnd('\') -ine $Dir.TrimEnd('\')) { throw "Refusing to write $Path`: it is not directly in $Dir" }
    Assert-EoNoLinkChain $Dir 'the folder'
    if ($null -ne (Get-EoEntryAttributes $Path)) { throw "Refusing to write $Path`: something already exists there (it is never overwritten)." }
    $enc = New-Object System.Text.UTF8Encoding $([bool]$Bom)
    $bytes = @($enc.GetPreamble()) + @($enc.GetBytes($Text))
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write([byte[]]$bytes, 0, $bytes.Count) } finally { $fs.Dispose() }
}

# The VM id 02 recorded in $EO.VmIdFile (in the admin-only root), as a GUID string, or
# '' when there is none. Throws when the file is a link or a folder or holds no GUID.
function Read-EoVmIdFile([string]$Path = $EO.VmIdFile) {
    $f = Get-EoPathFacts $Path -NoAcl
    if (-not $f.Exists) { return '' }
    if ($f.Reparse -or $f.Container) { throw "$Path is a link or a folder, not the VM id 02 wrote" }
    $t = ([System.IO.File]::ReadAllText($Path)).Trim()
    $g = [guid]::Empty
    if (-not [guid]::TryParse($t, [ref]$g)) { throw "$Path does not hold a VM id ('$t')" }
    return $g.ToString()
}

# Problems with the chain as it is now: no link from the drive root down to the iso
# folder, the parent (when present) passing the parent check, and the root and iso
# (when present) passing the root check, with $VmId's account allowed read access.
# No ACL is read through a link. The paths default to $EO's; the self-test passes its own.
function Get-EoVmChainProblems([string]$VmId = '', [string]$Parent = $EO.VmParent, [string]$Root = $EO.Root, [string]$IsoDir = $EO.IsoDir) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($x in @(Get-EoChainProblems $IsoDir)) { $p.Add($x) }
    if ($p.Count) { return $p }
    $vmSid = ConvertTo-EoVmSid $VmId
    $pf = Get-EoPathFacts $Parent
    if ($pf.Exists) { foreach ($x in @(Test-EoPathFacts $pf 'parent' -Container)) { $p.Add($x) } }
    foreach ($d in @($Root, $IsoDir)) {
        $f = Get-EoPathFacts $d
        if ($f.Exists) { foreach ($x in @(Test-EoPathFacts $f 'root' -Container -VmSid $vmSid)) { $p.Add($x) } }
    }
    return $p
}

# Throws unless Get-EoVmChainProblems finds nothing. 02 calls it immediately before
# each create, the ISO copy, each New-VHD, New-VM and the attaches.
function Assert-EoVmChain([string]$Action, [string]$VmId = '') {
    $p = @(Get-EoVmChainProblems $VmId)
    if ($p.Count) { throw "Refusing to $Action`: $($p -join '; '). Investigate who changed these folders before running undo-02-vm.ps1." }
}

# Problems that stop undo-02: the chain (no link, the parent admin-protected, root and
# iso Administrators and SYSTEM only, $VmId's account read at most) and what the root
# holds (Test-EoVmTree: expected entries only, no link anywhere, everything listable;
# with -AllowUnreadable a running VM's runtime folder may be unlistable). Nothing to
# check when the root is absent, apart from the chain.
function Get-EoVmTreeProblems([string]$VmId = '', [switch]$AllowUnreadable, [string]$Parent = $EO.VmParent, [string]$Root = $EO.Root, [string]$IsoDir = $EO.IsoDir) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($x in @(Get-EoVmChainProblems $VmId $Parent $Root $IsoDir)) { $p.Add($x) }
    if ($p.Count) { return $p }
    if ($null -eq (Get-EoEntryAttributes $Root)) { return $p }
    foreach ($x in @(Test-EoVmTree @(Get-EoTreeEntries $Root -Tolerant:$AllowUnreadable) -AllowUnreadable:$AllowUnreadable -Root $Root)) { $p.Add($x) }
    return $p
}

# The undo's view of the world when it printed its plan, against now (after the typed
# confirmation): whether the VM and the root exist, and the VM id. Any difference means
# the plan the operator confirmed is not what would happen, so the undo stops. Pure.
# $Planned, $Now: @{ VmPresent; RootPresent; VmId }.
function Test-EoUndoPlanStill($Planned, $Now) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'VmPresent', 'RootPresent', 'VmId') {
        if ("$($Planned[$k])" -ne "$($Now[$k])") { $p.Add("$k was '$($Planned[$k])' in the plan and is '$($Now[$k])' now") }
    }
    return $p
}

# Prints icacls for every level of the chain down to $IsoDir that exists and is not a
# link (stopping at the first link), and for every entry below $Root, for the
# transcript. Read-only; never fails the caller.
function Show-EoVmFolderAcls([string]$Root = $EO.Root, [string]$IsoDir = $EO.IsoDir) {
    try {
        $paths = New-Object System.Collections.Generic.List[string]
        $linked = $false
        foreach ($c in @(Get-EoAncestorPaths $IsoDir | Select-Object -Skip 1)) {
            $f = Get-EoPathFacts $c -NoAcl
            if (-not $f.Exists) { break }
            if ($f.Reparse) { Write-Host "  $c is a link (reparse point); not followed"; $linked = $true; break }
            $paths.Add($c)
        }
        if (-not $linked -and $null -ne (Get-EoEntryAttributes $Root)) {
            foreach ($e in @(Get-EoTreeEntries $Root -Tolerant)) {
                if ($e.Reparse) { Write-Host "  $($e.Full) is a link (reparse point); not followed" }
                else { if ($e.Rel -ine (Split-Path -Leaf $IsoDir)) { $paths.Add($e.Full) } }
                if ($e.Unreadable) { Write-Host "  $($e.Full) could not be listed (access denied)" }
            }
        }
        foreach ($x in $paths) { Invoke-EoNative icacls.exe @($x) -AllowFail | Write-Host }
    } catch { Write-Host "note: ACL listing stopped: $($_.Exception.Message)" }
}

# Deletes $Root and everything below it, entry by entry, deepest first, never through
# a link:
#   - Test-EoDeletableRoot must pass ($Root is never the 01b/01c record folder, the
#     evidence folder, anything in the user profile, or anything holding them);
#   - no folder from the drive root down to $Root is a link, and nothing below it is
#     one (enumerated without following links), or nothing is deleted;
#   - right before each delete, the entry and every folder above it are read again and
#     must still not be links;
#   - files are deleted one by one and folders only when empty (non-recursive), so a
#     link that appeared after the listing is at worst removed itself, never followed,
#     and an entry that appeared after the listing stops the delete.
# What remains: a folder above an entry turned into a junction between that entry's
# re-check and its delete call would redirect that one call. For $EO.Root every folder
# involved is writable by Administrators and SYSTEM only (undo-02 checks that with
# Get-EoVmTreeProblems first), and the scratch folders are admin-only too, so only an
# administrator could do it. Neither .NET Framework nor PowerShell offers a delete
# relative to an open folder handle that would close that last window without native code.
function Remove-EoVerifiedTree([string]$Root) {
    $bad = @(Test-EoDeletableRoot $Root)
    if ($bad.Count) { throw "Refusing to delete '$Root': $($bad -join '; ')" }
    $Root = $Root.TrimEnd('\')
    $noLink = {
        param([string]$Path)
        $chain = @(Get-EoChainProblems ([System.IO.Path]::GetDirectoryName($Path)))
        $self = Get-EoPathFacts $Path -NoAcl
        if ($self.Exists -and $self.Reparse) { $chain += "$Path is a link (reparse point)" }
        if ($chain.Count) { throw "Refusing to delete under '$Root': $($chain -join '; '). Nothing more was deleted; investigate." }
        return $self
    }
    $top = & $noLink $Root
    if (-not $top.Exists) { return }
    if (-not $top.Container) { throw "Refusing to delete '$Root': it is a file, want a folder" }
    $entries = @(Get-EoTreeEntries $Root)
    $links = @($entries | Where-Object { $_.Reparse })
    if ($links.Count) { throw "Refusing to delete '$Root': it holds links (reparse points): $(($links | ForEach-Object { $_.Rel }) -join ', '). Nothing was deleted; investigate." }
    $ordered = @($entries | Sort-Object -Property @{ Expression = { @("$($_.Rel)" -split '\\').Count } } -Descending)
    foreach ($e in $ordered + @([pscustomobject]@{ Rel = ''; Full = $Root; Container = $true; Reparse = $false })) {
        $now = & $noLink $e.Full
        if (-not $now.Exists) { throw "Refusing to go on deleting '$Root': '$($e.Full)' vanished after it was listed; investigate." }
        if ([bool]$now.Container -ne [bool]$e.Container) { throw "Refusing to go on deleting '$Root': '$($e.Full)' changed between file and folder after it was listed; investigate." }
        $a = [int](Get-EoEntryAttributes $e.Full)
        if (($a -band 1) -ne 0) { [System.IO.File]::SetAttributes($e.Full, [System.IO.FileAttributes]($a -band (-bnot 1))) }
        if ($e.Container) { [System.IO.Directory]::Delete($e.Full, $false) } else { [System.IO.File]::Delete($e.Full) }
    }
}

# The VM folder facts verify-host and 02 report, as rows: @{ <check> = <problems> }.
# A key starting with 'INFO ' is information, not a check (its values are notes).
# $VmId: the id of VM eo-l2 (its account is the only VM account accepted). Read-only.
function Get-EoVmFolderReport([string]$VmId = '') {
    $r = [ordered]@{}
    $vmSid = ConvertTo-EoVmSid $VmId
    $chainName = "VM folders: no link (reparse point) from C:\ down to $($EO.IsoDir)"
    $r[$chainName] = @(Get-EoChainProblems $EO.IsoDir)
    $names = @(
        "$($EO.VmParent): owner an administrator, no write-class right for any other account",
        "$($EO.Root): owner Administrators or SYSTEM, inheritance off, Administrators and SYSTEM only (this VM's account read only)",
        "$($EO.IsoDir): owner Administrators or SYSTEM, inheritance off, Administrators and SYSTEM only (this VM's account read only)",
        "System and anchor VHDX: not links; owner an administrator or this VM's account; Administrators, SYSTEM and this VM's account only",
        "Installer ISO (if still there): not a link; owner an administrator or this VM's account; Administrators, SYSTEM and this VM's account only",
        "$($EO.Root) holds only step 02's files and the VM configuration, no link inside",
        "VM configuration under $($EO.Root)\$($EO.VmName): Administrators, SYSTEM and this VM's account only")
    if (@($r[$chainName]).Count) {
        foreach ($n in $names) { $r[$n] = @('not read: a folder in the chain is a link') }
        return $r
    }
    $r[$names[0]] = @(Test-EoPathFacts (Get-EoPathFacts $EO.VmParent) 'parent' -Container)
    $r[$names[1]] = @(Test-EoPathFacts (Get-EoPathFacts $EO.Root) 'root' -Container -VmSid $vmSid)
    $isoFacts = Get-EoPathFacts $EO.IsoDir
    $r[$names[2]] = @(if ($isoFacts.Exists) { Test-EoPathFacts $isoFacts 'root' -Container -VmSid $vmSid })
    $r[$names[3]] = @(@($EO.SystemVhd, $EO.AnchorVhd) | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_) 'vm' -VmSid $vmSid })
    $isoFiles = @(if ($isoFacts.Exists -and -not $isoFacts.Reparse) { Get-EoTreeEntries $EO.IsoDir | Where-Object { -not $_.Container -and -not $_.Reparse } })
    $r[$names[4]] = @($isoFiles | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_.Full) 'vm' -VmSid $vmSid })
    $tree = @(if ($null -ne (Get-EoEntryAttributes $EO.Root)) { Get-EoTreeEntries $EO.Root -Tolerant })
    $treeP = @(Test-EoVmTree $tree -AllowUnreadable)
    $recorded = ''
    try { $recorded = Read-EoVmIdFile } catch { $treeP += "$($EO.VmIdFile): $($_.Exception.Message)" }
    if ($recorded -and $VmId -and $recorded -ne ([guid]$VmId).ToString()) { $treeP += "$($EO.VmIdFile) records VM id $recorded, but VM $($EO.VmName) has id $VmId" }
    $r[$names[5]] = $treeP
    $vmDir = Join-Path $EO.Root $EO.VmName
    $vmEntries = @($tree | Where-Object { -not $_.Reparse -and ("$($_.Rel)" -ieq $EO.VmName -or "$($_.Rel)".StartsWith("$($EO.VmName)\", [System.StringComparison]::OrdinalIgnoreCase)) })
    $r[$names[6]] = @(if (-not $vmEntries.Count) { "$vmDir not found" } else { $vmEntries | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_.Full) 'vm' -Container:([bool]$_.Container) -VmSid $vmSid } })
    $unread = @($tree | Where-Object { $_.Unreadable } | ForEach-Object { $_.Rel })
    if ($unread.Count) { $r['INFO VM runtime folders not listed (access denied while the VM runs; undo-02 lists them once the VM is off)'] = $unread }
    return $r
}

# The members of the local group with this SID, as strings, for an INFO row in
# verify-host (Hyper-V Administrators, S-1-5-32-578, may manage VMs and their files
# without being administrators; nothing here judges the list). Get-LocalGroupMember
# first; it fails on a group holding an orphaned SID, so ADSI (WinNT) is the fallback,
# with the group's local name from its SID. A one-entry 'not read: ...' list when
# neither works. Read-only.
function Get-EoLocalGroupMemberNames([string]$Sid) {
    $first = ''
    try { return @(Get-LocalGroupMember -SID $Sid -ErrorAction Stop | ForEach-Object { "$($_.Name) ($($_.SID))" }) }
    catch { $first = $_.Exception.Message }
    try {
        $name = ((New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1]
        $g = [ADSI]"WinNT://./$name,group"
        return @(@($g.psbase.Invoke('Members')) | ForEach-Object { "$($_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null))" })
    } catch { return @("not read: $first; $($_.Exception.Message)") }
}
