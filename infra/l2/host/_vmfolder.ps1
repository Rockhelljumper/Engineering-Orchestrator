# VM folder checks for step 02, its undo and verify-host. Dot-sourced by
# _common.ps1; it changes nothing on its own.
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
#     off, Administrators and SYSTEM only;
#   - the disks, the ISO and the VM configuration: no link, owner Administrators or
#     SYSTEM, access for Administrators, SYSTEM and Hyper-V's per-VM account only;
#   - C:\Hyper-V\eo-l2 holds only what step 02 and Hyper-V put there (Test-EoVmTree).
#
# Test-* functions are pure: they take plain facts and return a list of problems
# (empty when all is well), so tests/selftest.ps1 can drive them without elevation
# or Hyper-V. Get-* functions read the facts; New-/Remove-/Assert- act or throw.

$EoSidAdmins = 'S-1-5-32-544'
$EoSidSystem = 'S-1-5-18'
$EoSidUsers = 'S-1-5-32-545'
$EoSidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$EoSidCreatorOwner = 'S-1-3-0'
# NT VIRTUAL MACHINE\<VM id>: the account a VM's worker process runs as. Hyper-V adds
# it to the files it attaches (disks, ISO) and to the VM's configuration.
$EoVmSidPattern = '\AS-1-5-83-1-\d+-\d+-\d+-\d+\z'

# Rights that let an account change a folder or file, add to it, delete it or what is
# in it, or change its permissions or owner: WriteData/CreateFiles 0x2,
# AppendData/CreateDirectories 0x4, WriteExtendedAttributes 0x10,
# DeleteSubdirectoriesAndFiles 0x40, WriteAttributes 0x100, Delete 0x10000,
# ChangePermissions 0x40000, TakeOwnership 0x80000, MAXIMUM_ALLOWED 0x2000000,
# GENERIC_ALL 0x10000000, GENERIC_WRITE 0x40000000 (generic bits appear in inherit-only
# entries such as CREATOR OWNER).
$EoWriteRights = [int64](0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x2000000 -bor 0x10000000 -bor 0x40000000)

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

# The attributes of $Path itself (a link is not followed for the last component), or
# $null when nothing is there. A dangling link is reported, not taken as absent.
function Get-EoEntryAttributes([string]$Path) {
    try { return [System.IO.File]::GetAttributes($Path) }
    catch {
        $e = $_.Exception
        while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) { return $null }
        throw
    }
}

# Owner, inheritance and entries of a FileSystemSecurity (from Get-Acl, or the one
# New-EoDirSecurity builds) as plain facts: @{ Owner; Protected; Aces }.
function ConvertTo-EoSecurityFacts($Security) {
    $sid = [System.Security.Principal.SecurityIdentifier]
    $o = $Security.GetOwner($sid)
    $aces = @($Security.GetAccessRules($true, $true, $sid) | ForEach-Object {
            @{ Sid = "$($_.IdentityReference.Value)"; Allow = ("$($_.AccessControlType)" -eq 'Allow'); Rights = [int64]$_.FileSystemRights
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
# take access away and are not counted. $Kind:
#   parent  C:\Hyper-V as found. Owner Administrators, SYSTEM or TrustedInstaller.
#           Inheritance may be on, but no Allow entry, inherited or explicit, may give
#           a write-class right ($EoWriteRights) to any account other than those three;
#           read-only entries for other accounts are accepted (Users and Explorer
#           traverse it; other VMs may live there). CREATOR OWNER is accepted only as an
#           inherit-only entry: it never applies to C:\Hyper-V itself, and stands only
#           for whoever creates a child, which this rule limits to those three accounts.
#           With -New (02 just created it): owner Administrators, inheritance off, and
#           only Administrators, SYSTEM and Users (read only), nothing else.
#   root    C:\Hyper-V\eo-l2 and its iso folder: owner Administrators or SYSTEM
#           (Administrators with -New), inheritance off, Allow entries for
#           Administrators and SYSTEM only (CREATOR OWNER and the VM account included
#           in "any other").
#   vm      the disks, the ISO and the VM configuration: owner Administrators, SYSTEM or
#           a per-VM account (NT VIRTUAL MACHINE\<VM id>, S-1-5-83-1-a-b-c-d; the VM's
#           worker process may create its runtime files), inheritance may be on, Allow
#           entries for Administrators, SYSTEM and a per-VM account only.
# -Container says whether a folder (or a file) is expected.
function Test-EoPathFacts($Facts, [string]$Kind, [switch]$Container, [switch]$New) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($Kind -notin @('parent', 'root', 'vm')) { throw "Test-EoPathFacts: unknown kind '$Kind'" }
    $path = "$($Facts.Path)"
    if (-not $Facts.Exists) { $p.Add("$path does not exist"); return $p }
    if ($Facts.Reparse) { $p.Add("$path is a link (reparse point: junction, symbolic link or mount point)"); return $p }
    if ([bool]$Facts.Container -ne [bool]$Container) { $p.Add("$path is $(if ($Facts.Container) { 'a folder' } else { 'a file' }), want $(if ($Container) { 'a folder' } else { 'a file' })") }
    $owners = if ($New) { @($EoSidAdmins) } elseif ($Kind -eq 'parent') { @($EoSidAdmins, $EoSidSystem, $EoSidTrustedInstaller) } else { @($EoSidAdmins, $EoSidSystem) }
    $vmOwned = ($Kind -eq 'vm' -and "$($Facts.Owner)" -match $EoVmSidPattern)
    if ("$($Facts.Owner)" -notin $owners -and -not $vmOwned) { $p.Add("$path is owned by $($Facts.Owner), want $(if ($New) { 'Administrators' } elseif ($Kind -eq 'parent') { 'Administrators, SYSTEM or TrustedInstaller' } elseif ($Kind -eq 'vm') { 'Administrators, SYSTEM or the VM account' } else { 'Administrators or SYSTEM' })") }
    if (($Kind -eq 'root' -or $New) -and -not $Facts.Protected) { $p.Add("$path inherits permissions from its parent") }
    $allows = @(@($Facts.Aces) | Where-Object { $_ -and $_.Allow })
    if (-not $allows.Count) { $p.Add("$path has no access entries (an empty or null ACL)") }
    $admin = if ($Kind -eq 'parent' -and -not $New) { @($EoSidAdmins, $EoSidSystem, $EoSidTrustedInstaller) } else { @($EoSidAdmins, $EoSidSystem) }
    foreach ($a in $allows) {
        $sid = "$($a.Sid)"
        if ($sid -in $admin) { continue }
        $rights = [int64]$a.Rights
        $write = (($rights -band $EoWriteRights) -ne 0)
        $what = '{0} (rights 0x{1:X}{2}{3})' -f $sid, $rights, $(if ($a.Inherited) { ', inherited' } else { '' }), $(if ($a.InheritOnly) { ', inherit-only' } else { '' })
        if ($Kind -eq 'parent' -and $New) {
            if ($sid -eq $EoSidUsers -and -not $write) { continue }
            $p.Add("$path grants $what; a new C:\Hyper-V may grant only Administrators, SYSTEM and Users (read)")
        } elseif ($Kind -eq 'parent') {
            if (-not $write) { continue }
            if ($sid -eq $EoSidCreatorOwner -and $a.InheritOnly) { continue }
            $p.Add("$path grants a write-class right to $what; only Administrators, SYSTEM and TrustedInstaller may have one")
        } elseif ($Kind -eq 'vm') {
            if ($sid -match $EoVmSidPattern) { continue }
            $p.Add("$path grants access to $what; only Administrators, SYSTEM and the VM's own account may have access")
        } else {
            $p.Add("$path grants access to $what; only Administrators and SYSTEM may have access")
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

# Every entry below $Root, read without following links: a folder that is a link is
# listed (Reparse) but not entered. @{ Rel (path below $Root); Full; Container; Reparse }.
function Get-EoTreeEntries([string]$Root) {
    $out = New-Object System.Collections.Generic.List[object]
    $base = $Root.TrimEnd('\')
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($base)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($full in @([System.IO.Directory]::GetFileSystemEntries($dir))) {
            $a = [int][System.IO.File]::GetAttributes($full)
            $e = [pscustomobject]@{ Rel = $full.Substring($base.Length).TrimStart('\'); Full = $full; Container = (($a -band 0x10) -ne 0); Reparse = (($a -band 0x400) -ne 0) }
            $out.Add($e)
            if ($e.Container -and -not $e.Reparse) { $stack.Push($full) }
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
#   iso                                        folder, holding only *.iso files
#   eo-l2                                      folder (the VM's, from New-VM -Path)
#   eo-l2\Virtual Machines, eo-l2\Snapshots    folders, with anything below them
# Fewer entries are fine (02 stopped part way, or undo deleted part of it). Any link
# anywhere fails. Pure.
function Test-EoVmTree($Entries, [string]$VmName = $EO.VmName) {
    $p = New-Object System.Collections.Generic.List[string]
    $sysVhd = Split-Path -Leaf $EO.SystemVhd; $ancVhd = Split-Path -Leaf $EO.AnchorVhd; $iso = Split-Path -Leaf $EO.IsoDir
    foreach ($e in @($Entries)) {
        $rel = "$($e.Rel)"
        if ($e.Reparse) { $p.Add("$rel is a link (reparse point) inside $($EO.Root)"); continue }
        $parts = @($rel -split '\\')
        $dir = [bool]$e.Container
        $ok = $false
        if ($parts.Count -eq 1) {
            $ok = (($rel -ieq $sysVhd -or $rel -ieq $ancVhd) -and -not $dir) -or (($rel -ieq $iso -or $rel -ieq $VmName) -and $dir)
        } elseif ($parts[0] -ieq $iso) {
            $ok = ($parts.Count -eq 2 -and -not $dir -and $parts[1] -like '*.iso')
        } elseif ($parts[0] -ieq $VmName) {
            $ok = ($parts[1] -iin $EoVmConfigDirs) -and ($parts.Count -gt 2 -or $dir)
        }
        if (-not $ok) { $p.Add("$rel ($(if ($dir) { 'folder' } else { 'file' })) is not something step 02 or Hyper-V creates in $($EO.Root)") }
    }
    return $p
}

# Problems that make a path unfit for Remove-EoVerifiedTree: it must be a full, normal
# path at least two folders below a drive root; it must not be, hold or sit inside the
# 01b/01c record folder ($EO.GuardDir), the evidence folder, ProgramData or Windows,
# and must not be or hold the user profile (a folder inside the profile, such as the
# self-test's temporary folder, is allowed). Pure (string work only).
function Test-EoDeletableRoot([string]$Root) {
    $p = New-Object System.Collections.Generic.List[string]
    if (-not $Root -or -not [System.IO.Path]::IsPathRooted($Root) -or $Root -notmatch '\A[A-Za-z]:\\') { $p.Add("'$Root' is not a full path on a drive"); return $p }
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -ine $Root.TrimEnd('\')) { $p.Add("'$Root' is not in normal form (it resolves to '$full')") }
    if (@($full.Substring([System.IO.Path]::GetPathRoot($full).Length) -split '\\' | Where-Object { $_ }).Count -lt 2) { $p.Add("'$Root' is less than two folders below its drive root") }
    foreach ($keep in @($EO.GuardDir, $EO.Evidence, $env:ProgramData, $env:windir, $env:USERPROFILE)) {
        if (-not $keep) { continue }
        $k = $keep.TrimEnd('\')
        if ($full -ieq $k -or $k.StartsWith("$full\", [System.StringComparison]::OrdinalIgnoreCase)) { $p.Add("'$Root' is or holds '$k'") }
        elseif ($full.StartsWith("$k\", [System.StringComparison]::OrdinalIgnoreCase) -and $k -ine "$env:USERPROFILE".TrimEnd('\')) { $p.Add("'$Root' is inside '$k'") }
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

# Creates one folder (its parent must exist) with New-EoDirSecurity applied in the
# create call itself, so it never exists with an inherited ACL: DirectoryInfo.Create
# (DirectorySecurity) on Windows PowerShell 5.1 (.NET Framework), or
# FileSystemAclExtensions.Create on PowerShell 7. Refuses a path that already exists.
# The create calls succeed silently when the folder appeared in between, so the
# caller must read it back with Assert-EoNewDir before using it; an unprivileged
# account that won that race owns the folder, which Assert-EoNewDir refuses.
# Fallback when neither call exists: create, set the ACL, then the same read-back. Its
# window lets a standard user who opened a handle to C:\Hyper-V between the create and
# the ACL keep that handle (access is checked when a handle is opened); the read-back
# still refuses an entry they made, but not a handle they hold. Both supported
# editions have an atomic call, so the fallback should not run; it says so when it does.
function New-EoSecureDir([string]$Path, [switch]$Parent) {
    if ($null -ne (Get-EoEntryAttributes $Path)) { throw "$Path already exists; refusing to reuse it." }
    # The create calls would also make missing parents; only one level is made here.
    $up = Get-EoPathFacts ([System.IO.Path]::GetDirectoryName($Path)) -NoAcl
    if (-not $up.Exists -or $up.Reparse -or -not $up.Container) { throw "Refusing to create $Path`: its parent $($up.Path) is missing, a link or not a folder." }
    # Get-Acl loads the ACL types on PowerShell 7 (and shows the parent can be read);
    # the extension class lives in System.IO.FileSystem.AccessControl there, which
    # Windows PowerShell 5.1 (.NET Framework) does not have.
    $null = Get-Acl -LiteralPath ([System.IO.Path]::GetDirectoryName($Path))
    try { $null = [System.Reflection.Assembly]::Load('System.IO.FileSystem.AccessControl') } catch { }
    $sec = New-EoDirSecurity -Parent:$Parent
    $di = New-Object System.IO.DirectoryInfo $Path
    $net = [System.IO.DirectoryInfo].GetMethod('Create', [type[]]@([System.Security.AccessControl.DirectorySecurity]))
    $ext = $null
    foreach ($asm in @([System.Security.AccessControl.DirectorySecurity].Assembly) + @([AppDomain]::CurrentDomain.GetAssemblies())) {
        $t = $null
        try { $t = $asm.GetType('System.IO.FileSystemAclExtensions', $false) } catch { }
        if ($t) { $ext = $t; break }
    }
    if ($net) {
        $di.Create($sec)
        Write-Host "created $Path with its ACL in the create call (DirectoryInfo.Create)"
    } elseif ($ext) {
        $ext::Create($di, $sec)
        Write-Host "created $Path with its ACL in the create call (FileSystemAclExtensions.Create)"
    } else {
        Write-Host "warning: no create call that takes an ACL; creating $Path, then setting its ACL (see New-EoSecureDir)"
        New-Item -ItemType Directory -Path $Path | Out-Null
        Set-Acl -LiteralPath $Path -AclObject $sec
    }
}

# Throws unless $Path (just made by New-EoSecureDir) is a folder, not a link, owned by
# Administrators, with exactly the planned protected ACL, and empty; and no folder
# above it is a link.
function Assert-EoNewDir([string]$Path, [switch]$Parent) {
    $p = @(Test-EoChainFacts @(Get-EoAncestorPaths $Path | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))
    if (-not $p.Count) {
        $p = @(Test-EoPathFacts (Get-EoPathFacts $Path) $(if ($Parent) { 'parent' } else { 'root' }) -Container -New)
        if (-not $p.Count) {
            $names = @(Get-EoDirNames $Path)
            if ($names.Count) { $p += "$Path is not empty right after it was created: $($names -join ', ')" }
        }
    }
    if ($p.Count) { throw "Refusing to use $Path, which this step just created: $($p -join '; '). Someone else may have made or changed it; investigate before running undo-02-vm.ps1." }
    Write-Host "checked $Path`: not a link, owner Administrators, inheritance off, the planned entries only, empty"
}

# Problems with the chain as it is now: no link from C:\ down to the iso folder,
# C:\Hyper-V (when present) passing the parent check, and eo-l2 and iso (when
# present) passing the root check. No ACL is read through a link.
function Get-EoVmChainProblems {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($x in @(Test-EoChainFacts @(Get-EoAncestorPaths $EO.IsoDir | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))) { $p.Add($x) }
    if ($p.Count) { return $p }
    $pf = Get-EoPathFacts $EO.VmParent
    if ($pf.Exists) { foreach ($x in @(Test-EoPathFacts $pf 'parent' -Container)) { $p.Add($x) } }
    foreach ($d in @($EO.Root, $EO.IsoDir)) {
        $f = Get-EoPathFacts $d
        if ($f.Exists) { foreach ($x in @(Test-EoPathFacts $f 'root' -Container)) { $p.Add($x) } }
    }
    return $p
}

# Throws unless Get-EoVmChainProblems finds nothing. 02 calls it immediately before
# each create, the ISO copy, each New-VHD and New-VM.
function Assert-EoVmChain([string]$Action) {
    $p = @(Get-EoVmChainProblems)
    if ($p.Count) { throw "Refusing to $Action`: $($p -join '; '). Investigate who changed these folders before running undo-02-vm.ps1." }
}

# Problems that stop undo-02 before it changes anything, and again right before it
# deletes: the chain (no link, C:\Hyper-V admin-protected, eo-l2 and iso Administrators
# and SYSTEM only) and what eo-l2 holds (Test-EoVmTree: expected entries only, no link
# anywhere). Nothing to check when eo-l2 is absent, apart from the chain.
function Get-EoVmTreeProblems {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($x in @(Get-EoVmChainProblems)) { $p.Add($x) }
    if ($p.Count) { return $p }
    if ($null -eq (Get-EoEntryAttributes $EO.Root)) { return $p }
    foreach ($x in @(Test-EoVmTree @(Get-EoTreeEntries $EO.Root))) { $p.Add($x) }
    return $p
}

# Deletes $Root and everything below it, entry by entry, deepest first, never through
# a link:
#   - Test-EoDeletableRoot must pass ($Root is never the 01b/01c record folder, the
#     evidence folder or anything holding them);
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
# Get-EoVmTreeProblems first), so only an administrator could do it. Neither .NET
# Framework nor PowerShell offers a delete relative to an open folder handle that
# would close that last window without native code.
function Remove-EoVerifiedTree([string]$Root) {
    $bad = @(Test-EoDeletableRoot $Root)
    if ($bad.Count) { throw "Refusing to delete '$Root': $($bad -join '; ')" }
    $Root = $Root.TrimEnd('\')
    $noLink = {
        param([string]$Path)
        $chain = @(Test-EoChainFacts @(Get-EoAncestorPaths ([System.IO.Path]::GetDirectoryName($Path)) | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))
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
# Read-only. Needs the VM's folder to exist (02 done).
function Get-EoVmFolderReport {
    $r = [ordered]@{}
    $chainName = "VM folders: no link (reparse point) from C:\ down to $($EO.IsoDir)"
    $r[$chainName] = @(Test-EoChainFacts @(Get-EoAncestorPaths $EO.IsoDir | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))
    $names = @(
        "$($EO.VmParent): owner an administrator, no write-class right for any other account",
        "$($EO.Root): owner Administrators or SYSTEM, inheritance off, Administrators and SYSTEM only",
        "$($EO.IsoDir): owner Administrators or SYSTEM, inheritance off, Administrators and SYSTEM only",
        'System and anchor VHDX: not links; owner an administrator; Administrators, SYSTEM and the VM account only',
        'Installer ISO (if still there): not a link; owner an administrator; Administrators, SYSTEM and the VM account only',
        "$($EO.Root) holds only step 02's files and the VM configuration, no link inside",
        "VM configuration under $($EO.Root)\$($EO.VmName): Administrators, SYSTEM and the VM account only")
    if (@($r[$chainName]).Count) {
        foreach ($n in $names) { $r[$n] = @('not read: a folder in the chain is a link') }
        return $r
    }
    $r[$names[0]] = @(Test-EoPathFacts (Get-EoPathFacts $EO.VmParent) 'parent' -Container)
    $r[$names[1]] = @(Test-EoPathFacts (Get-EoPathFacts $EO.Root) 'root' -Container)
    $isoFacts = Get-EoPathFacts $EO.IsoDir
    $r[$names[2]] = @(if ($isoFacts.Exists) { Test-EoPathFacts $isoFacts 'root' -Container })
    $r[$names[3]] = @(@($EO.SystemVhd, $EO.AnchorVhd) | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_) 'vm' })
    $isoFiles = @(if ($isoFacts.Exists -and -not $isoFacts.Reparse) { Get-EoTreeEntries $EO.IsoDir | Where-Object { -not $_.Container -and -not $_.Reparse } })
    $r[$names[4]] = @($isoFiles | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_.Full) 'vm' })
    $tree = @(if ($null -ne (Get-EoEntryAttributes $EO.Root)) { Get-EoTreeEntries $EO.Root })
    $r[$names[5]] = @(Test-EoVmTree $tree)
    $vmDir = Join-Path $EO.Root $EO.VmName
    $vmEntries = @($tree | Where-Object { -not $_.Reparse -and ("$($_.Rel)" -ieq $EO.VmName -or "$($_.Rel)".StartsWith("$($EO.VmName)\", [System.StringComparison]::OrdinalIgnoreCase)) })
    $r[$names[6]] = @(if (-not $vmEntries.Count) { "$vmDir not found" } else { $vmEntries | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_.Full) 'vm' -Container:([bool]$_.Container) } })
    return $r
}
