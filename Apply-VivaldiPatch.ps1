<#
.SYNOPSIS
    Applies (or reverts / reports) small patches to Vivaldi's UI bundle, bundle.js.

.DESCRIPTION
    Patches (select some with -Only <name>[,<name>]):

      no-follow         "Move to Workspace" no longer follows the moved tab.
                        Since Vivaldi 8.0 the UI switches to the destination workspace whenever the tab you moved
                        is the ACTIVE tab (tabs.onUpdated listener -> setActiveWorkspace), which loads that
                        workspace. The patch makes PageActions.moveToWorkspace first activate the tab Vivaldi
                        would pick if the active tab were closed (or open a blank background tab when there is
                        none) and only then do the normal move, so nothing follows the moved tab.

      fullscreen-hint   The "Press Escape key to exit fullscreen." bubble is shown for -FullscreenHintMs
                        milliseconds (default 1000; 0 = never shown) instead of 4 seconds. The bubble component
                        gets an optional per-use duration; only the fullscreen hint passes one, so toasts and
                        every other use keep their 4 seconds.

    Safety:
      * Nothing is written unless every pattern of a patch matches EXACTLY once; otherwise that patch is skipped
        and the file is left as it was.
      * Idempotent: running it again on a patched file changes nothing.
      * Every inserted fragment is wrapped in /*vivmod:<name>:begin*/ ... /*vivmod:<name>:end*/ markers, so
        -Revert removes exactly that text and leaves everything else (including other tools' edits) alone.
      * The original file is kept once as bundle.js.vivmod.bak (inside the version folder, so it disappears
        together with the version folder on the next Vivaldi update).
      * The new file is written next to the old one, syntax-checked with Node.js when `node` is on PATH,
        swapped in, read back and compared; on any mismatch the original bytes are restored.
      * Only bundle.js is touched. Never vivaldi.exe / vivaldi.dll (Widevine verifies those).

    A Vivaldi update installs a new Application\<version> folder, so run this again after every update
    (close Vivaldi first; it takes effect the next time Vivaldi starts).

.PARAMETER AppDir
    The "Application" folder that contains the version folders. Default: the Application folder next to this
    script's parent folder, else %LOCALAPPDATA%\Vivaldi\Application, else Program Files\Vivaldi\Application.

.PARAMETER Version
    Patch this version folder (for example 8.2.4133.80) instead of the newest one.

.PARAMETER AllVersions
    Patch every version folder instead of only the newest one.

.PARAMETER BundlePath
    Patch exactly this bundle.js (testing or unusual layouts). Overrides AppDir / Version.

.PARAMETER Only
    Only process the named patch(es): no-follow, fullscreen-hint.

.PARAMETER FullscreenHintMs
    How long the fullscreen hint stays visible, in milliseconds (0 = never). Default 1000. If the patch is already
    applied with another value and you pass this option, the patch is updated to the new value.

.PARAMETER Status
    Read-only report per patch: PATCHED, NOT PATCHED (applies cleanly) or NOT APPLICABLE (pattern not found).

.PARAMETER Revert
    Remove the patch(es) again (removes exactly the inserted text).

.PARAMETER SkipSyntaxCheck
    Do not run the optional `node --check` before swapping the file in.

.PARAMETER LogPath
    Append a line to this log whenever the script changes a file or fails. Default: patch.log next to the script.

.EXAMPLE
    .\Apply-VivaldiPatch.ps1 -Status
.EXAMPLE
    .\Apply-VivaldiPatch.ps1 -WhatIf
.EXAMPLE
    .\Apply-VivaldiPatch.ps1
.EXAMPLE
    .\Apply-VivaldiPatch.ps1 -FullscreenHintMs 0
.EXAMPLE
    .\Apply-VivaldiPatch.ps1 -Revert -Only fullscreen-hint

    Exit codes: 0 ok / already in the requested state, 1 a pattern was not found or markers are damaged (nothing
    changed for that patch), 2 verification failed (original restored), 3 Vivaldi install not found, 4 cannot
    read/write the file, 10 (-Status only) nothing failed but something is not patched yet (it would apply
    cleanly). A failure always wins over 10.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AppDir,
    [string]$Version,
    [switch]$AllVersions,
    [string]$BundlePath,
    [string[]]$Only,
    [ValidateRange(0, 60000)][int]$FullscreenHintMs = 1000,
    [switch]$Status,
    [switch]$Revert,
    [switch]$SkipSyntaxCheck,
    [string]$LogPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Latin-1 maps bytes to chars 1:1, so the file round-trips byte-exactly whatever is inside it.
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:FullscreenHintExplicit = $PSBoundParameters.ContainsKey('FullscreenHintMs')
if (-not $LogPath) {
    $logDir = $PSScriptRoot
    if (-not $logDir) { $logDir = (Get-Location).Path }
    $LogPath = Join-Path $logDir 'patch.log'
}

function Say {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
}

function Write-Log {
    param([string]$Message)
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch { }
}

# ---------------------------------------------------------------------------------------------------------
# Patch: no-follow
# ---------------------------------------------------------------------------------------------------------

# What gets inserted (minified style). @@TOKENS@@ are replaced with the identifiers found in the bundle.
#   if ( destination workspace != active workspace  &&  the active page is one of the pages being moved ) {
#       next = <page Vivaldi would activate if these pages were closed>
#       if (next) activateTab(next) else { open a blank background tab; activateTab(it) }
#   }
$NoFollowTemplate = '/*vivmod:no-follow:begin*/' +
    'if((@@WS@@||0)!==(@@ACT@@||0)&&@@STORE@@.getActivePage(@@WIN@@)&&' +
    '@@LIST@@.some((__vm_p=>__vm_p.id===@@STORE@@.getActivePage(@@WIN@@).id))){' +
    'const __vm_n=(0,@@MOD@@.@@EXP@@)(@@LIST@@)?.id;' +
    'if(__vm_n)@@ACTS@@.activateTab(__vm_n,@@WIN@@);' +
    'else{const{pageId:__vm_e}=await @@ACTS@@.openURL(@@WIN@@,"",{inBackground:!0});@@ACTS@@.activateTab(__vm_e,@@WIN@@)}}' +
    '/*vivmod:no-follow:end*/'

function Get-NoFollowPlan {
    param([string]$Text, [hashtable]$Patch)

    # Head of PageActions.moveToWorkspace (names are minified and change between builds), for example:
    #   async function Pe(e,t,n=!1){const i=Ee(e)?e:N.aV.of(e),s=i.first().windowId,a=z.Z.getActiveWorkspaceId(s);
    $head = (
        'async function (?<fn>[\w$]+)\((?<pages>[\w$]+),(?<ws>[\w$]+)(?:,[\w$]+=!1)?\)\{' +
        'const (?<list>[\w$]+)=[\w$]+\(\k<pages>\)\?\k<pages>:[\w$.]+\.of\(\k<pages>\),' +
        '(?<win>[\w$]+)=\k<list>\.first\(\)\.windowId,' +
        '(?<act>[\w$]+)=[\w$.]+\.getActiveWorkspaceId\(\k<win>\);'
    )

    $candidates = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, $head)) {
        $from   = $m.Index + $m.Length
        $window = $Text.Substring($from, [Math]::Min(900, $Text.Length - $from))

        # It must be the function that calls tabsPrivate.move(... debug:"PageActions.moveToWorkspace").
        $dbg = $window.IndexOf('debug:"PageActions.moveToWorkspace"', [StringComparison]::Ordinal)
        if ($dbg -lt 0) { continue }
        $nextFn = $window.IndexOf('function ', [StringComparison]::Ordinal)
        if ($nextFn -ge 0 -and $nextFn -lt $dbg) { continue }

        $ws  = [regex]::Escape($m.Groups['ws'].Value)
        $win = [regex]::Escape($m.Groups['win'].Value)
        $act = [regex]::Escape($m.Groups['act'].Value)

        # ...which passes the destination workspace as workspaceId,
        $mv = [regex]::Match($window, 'tabsPrivate\.move\(\{[^}]{0,300}?workspaceId:' + $ws + '\|\|0,')
        # ...which looks at the pages left in the active workspace (gives us the PageStore alias),
        $gp = [regex]::Match($window, '(?<store>[\w$]+\.[\w$]+)\.getPages\(' + $win + ',\{workspaceId:' + $act + '\}\)\.size')
        # ...and which opens + activates a blank tab when that workspace is empty (gives us the PageActions alias).
        $op = [regex]::Match($window, '(?<acts>[\w$]+)\.openURL\(' + $win + ',"",\{inBackground:!0\}\)')
        if (-not ($mv.Success -and $gp.Success -and $op.Success)) { continue }
        $acts = $op.Groups['acts'].Value
        if ($window.IndexOf($acts + '.activateTab(', [StringComparison]::Ordinal) -lt 0) { continue }

        [void]$candidates.Add([pscustomobject]@{
            Index = $from
            Fn    = $m.Groups['fn'].Value
            Pages = $m.Groups['pages'].Value
            Ws    = $m.Groups['ws'].Value
            List  = $m.Groups['list'].Value
            Win   = $m.Groups['win'].Value
            Act   = $m.Groups['act'].Value
            Store = $gp.Groups['store'].Value
            Acts  = $acts
        })
    }
    if ($candidates.Count -ne 1) {
        throw ('PageActions.moveToWorkspace was found {0} time(s), expected exactly 1' -f $candidates.Count)
    }
    $c = $candidates[0]

    # The "which page gets activated when these pages go away" helper that Vivaldi's own moveToWindow uses:
    #   function ne(e){return e.some((e=>e.active))?(0,p.yz)(e)?.id:void 0}
    $nextPattern = (
        'function (?<fn>[\w$]+)\((?<a>[\w$]+)\)\{return \k<a>\.some\(\((?<b>[\w$]+)=>\k<b>\.active\)\)\?' +
        '\(0,(?<mod>[\w$]+)\.(?<exp>[\w$]+)\)\(\k<a>\)\?\.id:void 0\}'
    )
    $nm = [regex]::Matches($Text, $nextPattern)
    if ($nm.Count -ne 1) {
        throw ('next-page-to-activate helper was found {0} time(s), expected exactly 1' -f $nm.Count)
    }
    $mod = $nm[0].Groups['mod'].Value
    $exp = $nm[0].Groups['exp'].Value
    if ($c.Store.Split('.')[0] -ne $mod) {
        throw ('helper module alias "{0}" differs from the PageStore alias "{1}"' -f $mod, $c.Store)
    }

    $insert = $NoFollowTemplate.
        Replace('@@WS@@', $c.Ws).Replace('@@ACT@@', $c.Act).Replace('@@WIN@@', $c.Win).
        Replace('@@LIST@@', $c.List).Replace('@@STORE@@', $c.Store).Replace('@@ACTS@@', $c.Acts).
        Replace('@@MOD@@', $mod).Replace('@@EXP@@', $exp)
    if ($insert.Contains('@@')) { throw 'internal error: unreplaced token in the patch template' }

    return @{
        Edits = @(@{ Index = $c.Index; Insert = $insert })
        Info  = ('moveToWorkspace is {0}({1},{2}), PageStore is {3}' -f $c.Fn, $c.Pages, $c.Ws, $c.Store)
    }
}

# ---------------------------------------------------------------------------------------------------------
# Patch: fullscreen-hint
# ---------------------------------------------------------------------------------------------------------

function Get-FullscreenHintPlan {
    param([string]$Text, [hashtable]$Patch, [int]$Ms)

    # The shared "overlay info bubble" component (toasts, fullscreen hint, pointer-lock hint). Its auto-hide delay
    # is hard-coded as 4e3 in two places:
    #   class XU extends Fi.Component{constructor(e){super(e),this.state={hover:!1,show:!0}}
    #     componentDidMount(){this.hideSelf(4e3)} ... show=()=>{this.showSelf(),this.hideSelf(4e3)} ...}
    #   const KU=XU;
    $classPattern = (
        'class (?<cls>[\w$]+) extends [\w$.]+\{constructor\((?<p>[\w$]+)\)\{super\(\k<p>\),' +
        'this\.state=\{hover:!1,show:!0\}\}componentDidMount\(\)\{this\.hideSelf\(4e3\)\}'
    )
    $cm = [regex]::Matches($Text, $classPattern)
    if ($cm.Count -ne 1) {
        throw ('bubble component (constructor + componentDidMount) was found {0} time(s), expected exactly 1' -f $cm.Count)
    }
    $sm = [regex]::Matches($Text, 'show=\(\)=>\{this\.showSelf\(\),this\.hideSelf\(4e3\)\}')
    if ($sm.Count -ne 1) {
        throw ('bubble component show() was found {0} time(s), expected exactly 1' -f $sm.Count)
    }
    $gap = $sm[0].Index - ($cm[0].Index + $cm[0].Length)
    if ($gap -lt 0 -or $gap -gt 1500) { throw 'show() does not belong to the same component as componentDidMount()' }
    $cls = $cm[0].Groups['cls'].Value

    # The single place that renders the fullscreen hint:
    #   case"fullscreen":{...(0,I.Z)("Press Escape key to exit fullscreen.")...(0,Yi.jsx)(KU,{customData:n,onClose:a,overlayText:s})
    $needle = '"Press Escape key to exit fullscreen."'
    $first = $Text.IndexOf($needle, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw 'the fullscreen hint text was not found' }
    if ($Text.IndexOf($needle, $first + 1, [StringComparison]::Ordinal) -ge 0) { throw 'the fullscreen hint text occurs more than once' }
    $after = $Text.Substring($first, [Math]::Min(700, $Text.Length - $first))
    $jm = [regex]::Match($after,
        '\(0,[\w$]+\.jsx\)\((?<comp>[\w$]+),\{(?<props>customData:(?<n>[\w$]+),onClose:(?<a>[\w$]+),overlayText:(?<s>[\w$]+))\}\)')
    if (-not $jm.Success) { throw 'the call that renders the fullscreen hint was not found' }
    $comp = $jm.Groups['comp'].Value

    # That call must render the bubble component found above (const KU=XU;).
    $alias = [regex]::Matches($Text, 'const ' + [regex]::Escape($comp) + '=' + [regex]::Escape($cls) + '[,;]')
    if ($alias.Count -ne 1) {
        throw ('the fullscreen hint is not rendered by the bubble component ("{0}={1}" found {2} time(s))' -f $comp, $cls, $alias.Count)
    }

    $b = '/*vivmod:fullscreen-hint=' + $Ms + ':begin*/'
    $e = '/*vivmod:fullscreen-hint:end*/'
    $delay = $b + 'this.props.vmFsMs??' + $e          # hideSelf(this.props.vmFsMs??4e3)
    $prop  = $b + 'vmFsMs:' + $Ms + ',' + $e          # {vmFsMs:1000,customData:n,onClose:a,overlayText:s}
    $tail  = '4e3)}'.Length                           # both matches end with  4e3)}

    return @{
        Edits = @(
            @{ Index = $cm[0].Index + $cm[0].Length - $tail; Insert = $delay },
            @{ Index = $sm[0].Index + $sm[0].Length - $tail; Insert = $delay },
            @{ Index = $first + $jm.Groups['props'].Index;   Insert = $prop }
        )
        Info  = ('bubble component {0} (rendered as {1}), fullscreen hint {2}' -f $cls, $comp,
                 $(if ($Ms -eq 0) { 'hidden' } else { "shown for $Ms ms instead of 4000" }))
    }
}

# ---------------------------------------------------------------------------------------------------------
# Patch list. Name -> markers /*vivmod:<Name>[=<variant>]:begin*/ ... /*vivmod:<Name>:end*/
#   Plan            returns @{ Edits = @(@{Index; Insert}, ...); Info = '...' } or throws
#   Variant         value baked into the begin markers ($null = patch has no setting)
#   VariantExplicit $true when the user asked for a specific value on this run
# To add another patch later, add another hashtable to this list.
# ---------------------------------------------------------------------------------------------------------
$script:Patches = @(
    @{
        Name            = 'no-follow'
        Plan            = { param($Text, $Patch) Get-NoFollowPlan -Text $Text -Patch $Patch }
        Variant         = { $null }
        VariantExplicit = { $false }
        Describe        = { param($v) '' }
    },
    @{
        Name            = 'fullscreen-hint'
        Plan            = { param($Text, $Patch) Get-FullscreenHintPlan -Text $Text -Patch $Patch -Ms $FullscreenHintMs }
        Variant         = { [string]$FullscreenHintMs }
        VariantExplicit = { $script:FullscreenHintExplicit }
        Describe        = { param($v) $(if ($v -eq '0') { '(hint hidden)' } else { '(hint shown for ' + $v + ' ms)' }) }
    }
)

# ---------------------------------------------------------------------------------------------------------
# Generic machinery
# ---------------------------------------------------------------------------------------------------------

function Get-MarkerRegex {
    param([hashtable]$Patch)
    $n = [regex]::Escape($Patch.Name)
    return @{
        Begin = '/\*vivmod:' + $n + '(?:=(?<v>[^:*]*))?:begin\*/'
        End   = '/\*vivmod:' + $n + ':end\*/'
    }
}

function Get-PatchState {
    param([string]$Text, [hashtable]$Patch)
    $rx = Get-MarkerRegex -Patch $Patch
    $b = [regex]::Matches($Text, $rx.Begin)
    $e = [regex]::Matches($Text, $rx.End)
    if ($b.Count -eq 0 -and $e.Count -eq 0) { return @{ State = 'Absent'; Variant = $null } }
    if ($b.Count -ne $e.Count) { return @{ State = 'Damaged'; Variant = $null } }
    for ($i = 0; $i -lt $b.Count; $i++) {
        if ($b[$i].Index -ge $e[$i].Index) { return @{ State = 'Damaged'; Variant = $null } }
        if ($i + 1 -lt $b.Count -and $e[$i].Index -ge $b[$i + 1].Index) { return @{ State = 'Damaged'; Variant = $null } }
    }
    return @{ State = 'Applied'; Variant = $b[0].Groups['v'].Value }
}

function Remove-PatchBlocks {
    param([string]$Text, [hashtable]$Patch)
    $rx = Get-MarkerRegex -Patch $Patch
    return [regex]::Replace($Text, $rx.Begin + '[\s\S]*?' + $rx.End, '')
}

function Add-Edits {
    param([string]$Text, $Edits)
    foreach ($ed in @($Edits | Sort-Object { $_.Index } -Descending)) {
        $Text = $Text.Insert($ed.Index, $ed.Insert)
    }
    return $Text
}

function Resolve-AppDir {
    if ($AppDir) {
        if (-not (Test-Path -LiteralPath $AppDir -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]("-AppDir does not exist: $AppDir")
        }
        return $AppDir
    }
    $candidates = New-Object System.Collections.ArrayList
    if ($PSScriptRoot) { [void]$candidates.Add((Join-Path (Split-Path -Parent $PSScriptRoot) 'Application')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Vivaldi\Application')) }
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'Vivaldi\Application')) }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { [void]$candidates.Add((Join-Path $pf86 'Vivaldi\Application')) }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    return $null
}

function Get-Targets {
    if ($BundlePath) {
        if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]("-BundlePath does not exist: $BundlePath")
        }
        $p = (Resolve-Path -LiteralPath $BundlePath).Path
        return @([pscustomobject]@{ Version = '(explicit path)'; Path = $p })
    }
    $app = Resolve-AppDir
    if (-not $app) { throw [System.IO.DirectoryNotFoundException]'Vivaldi "Application" folder not found - pass -AppDir.' }
    $dirs = @(Get-ChildItem -LiteralPath $app -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' } |
        Sort-Object { [version]$_.Name } -Descending)
    if ($Version) { $dirs = @($dirs | Where-Object { $_.Name -eq $Version }) }
    elseif (-not $AllVersions) { $dirs = @($dirs | Select-Object -First 1) }
    $targets = @()
    foreach ($d in $dirs) {
        $p = Join-Path $d.FullName 'resources\vivaldi\bundle.js'
        if (Test-Path -LiteralPath $p -PathType Leaf) { $targets += [pscustomobject]@{ Version = $d.Name; Path = $p } }
    }
    if ($targets.Count -eq 0) { throw [System.IO.FileNotFoundException]("No resources\vivaldi\bundle.js found under $app") }
    return $targets
}

function Test-VivaldiRunning {
    param([string]$BundleFile)
    try {
        $root = $BundleFile
        for ($i = 0; $i -lt 4; $i++) { $root = Split-Path -Parent $root }   # ...\Application
        foreach ($proc in @(Get-Process -Name 'vivaldi' -ErrorAction SilentlyContinue)) {
            try { if ($proc.Path -and $proc.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true } } catch { }
        }
    }
    catch { }
    return $false
}

function Test-JsSyntax {
    param([string]$File)
    if ($SkipSyntaxCheck) { return $true }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Say '  (node not found - skipping the optional syntax check)' 'DarkGray'; return $true }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'     # Windows PowerShell 5.1 turns native stderr into errors otherwise
    try { & $node.Source --check $File 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
    return ($LASTEXITCODE -eq 0)
}

function Save-Bundle {
    param([string]$Path, [byte[]]$OriginalBytes, [string]$NewText, [bool]$MakeBackup)
    $dir = Split-Path -Parent $Path
    $bak = $Path + '.vivmod.bak'
    $tmp = Join-Path $dir 'bundle.vivmod-tmp.js'
    $newBytes = $script:Latin1.GetBytes($NewText)

    # Respect an explicit read-only flag instead of silently replacing the file.
    if ((Get-Item -LiteralPath $Path).IsReadOnly) {
        Say ('  the file is marked read-only - not touching it. Clear the flag first:  attrib -R "' + $Path + '"') 'Red'
        Write-Log ('REFUSED, file is read-only: ' + $Path)
        return 4
    }
    try {
        if ($MakeBackup -and -not (Test-Path -LiteralPath $bak)) {
            [System.IO.File]::WriteAllBytes($bak, $OriginalBytes)
            Say ('  backup written: ' + $bak) 'DarkGray'
        }
        [System.IO.File]::WriteAllBytes($tmp, $newBytes)
        if (-not (Test-JsSyntax $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Say '  syntax check FAILED - nothing was changed' 'Red'
            Write-Log ('FAILED syntax check, unchanged: ' + $Path)
            return 2
        }
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $why = $_.Exception.Message
        if ($_.Exception -is [System.UnauthorizedAccessException]) { $why += ' (read-only file or no permission - try an elevated prompt)' }
        else { $why += ' (is Vivaldi still running? close it and retry)' }
        Say ('  cannot write: ' + $why) 'Red'
        Write-Log ('FAILED to write ' + $Path + ': ' + $why)
        return 4
    }

    # Read back and compare with what we meant to write; restore the original bytes on any mismatch.
    $ok = $false
    try { $ok = [System.Linq.Enumerable]::SequenceEqual([byte[]]$newBytes, [byte[]][System.IO.File]::ReadAllBytes($Path)) } catch { }
    if (-not $ok) {
        try { [System.IO.File]::WriteAllBytes($Path, $OriginalBytes) } catch { }
        Say '  read-back verification FAILED - original restored' 'Red'
        Write-Log ('FAILED read-back, original restored: ' + $Path)
        return 2
    }
    return 0
}

function Invoke-Bundle {
    param($Target)
    $path = $Target.Path
    Say ('Vivaldi {0}  {1}' -f $Target.Version, $path) 'Cyan'

    try { $bytes = [System.IO.File]::ReadAllBytes($path) }
    catch { Say ('  cannot read the file: ' + $_.Exception.Message) 'Red'; return 4 }
    $text = $script:Latin1.GetString($bytes)
    $code = 0
    $pending = $false
    $changed = $false
    $touched = @()

    $selected = @($script:Patches | Where-Object { (-not $Only) -or ($Only -contains $_.Name) })
    if ($Revert) { [array]::Reverse($selected) }

    foreach ($patch in $selected) {
        $st = Get-PatchState -Text $text -Patch $patch
        $label = '  [{0}]' -f $patch.Name
        $want = & $patch.Variant
        $explicit = [bool](& $patch.VariantExplicit)

        if ($Revert) {
            switch ($st.State) {
                'Absent'  { Say "$label not applied - nothing to revert" }
                'Applied' {
                    $text = Remove-PatchBlocks -Text $text -Patch $patch
                    $changed = $true; $touched += $patch.Name
                    Say "$label will be removed" 'Yellow'
                }
                default {
                    Say "$label markers are damaged - cannot remove cleanly. Restore the backup instead:" 'Red'
                    Say ('      Copy-Item -LiteralPath "{0}.vivmod.bak" -Destination "{0}" -Force' -f $path) 'Red'
                    $code = [Math]::Max($code, 1)
                }
            }
            continue
        }

        if ($st.State -eq 'Damaged') {
            Say "$label markers are damaged (begin/end do not pair up) - not touching the file" 'Red'
            $code = [Math]::Max($code, 1)
            continue
        }

        $reapply = $false
        if ($st.State -eq 'Applied') {
            $differs = ($null -ne $want) -and $explicit -and ($st.Variant -ne $want)
            if (-not $differs) {
                $desc = [string](& $patch.Describe $st.Variant)
                if ($desc) { $desc = ' ' + $desc }
                if ($Status) { Say ($label + ' PATCHED' + $desc) 'Green' }
                else { Say ($label + ' already patched' + $desc + ' - no change') 'Green' }
                continue
            }
            $reapply = $true     # same patch, different setting: remove and apply again
        }

        # Absent (or being updated): can it be applied?
        $base = $text
        if ($reapply) { $base = Remove-PatchBlocks -Text $text -Patch $patch }
        try {
            $plan = & $patch.Plan $base $patch
            $new = Add-Edits -Text $base -Edits $plan.Edits
            if ((Remove-PatchBlocks -Text $new -Patch $patch) -cne $base) { throw 'internal error: revert round-trip mismatch' }
        }
        catch {
            Say ("$label NOT APPLICABLE to this build: " + $_.Exception.Message) 'Red'
            Say '      Nothing was changed for this patch. Vivaldi may have changed or fixed this code - the' 'Red'
            Say '      patterns in this script (Get-*Plan functions) need updating for this version.' 'Red'
            if (-not $Status) { Write-Log ('NOT APPLICABLE ' + $patch.Name + ' ' + $Target.Version + ': ' + $_.Exception.Message) }
            $code = [Math]::Max($code, 1)
            continue
        }
        if ($Status) {
            if ($reapply) { Say "$label PATCHED with another setting (is '$($st.Variant)', requested '$want') - would be updated" 'Yellow' }
            else { Say "$label NOT PATCHED (patch applies cleanly: $($plan.Info))" 'Yellow' }
            $pending = $true
        }
        else {
            $text = $new; $changed = $true; $touched += $patch.Name
            if ($reapply) { Say "$label will be updated ('$($st.Variant)' -> '$want'): $($plan.Info)" 'Yellow' }
            else { Say "$label will be applied: $($plan.Info)" 'Yellow' }
        }
    }

    if ($Status -or -not $changed) {
        if ($code -eq 0 -and $pending) { return 10 }
        return $code
    }

    if (Test-VivaldiRunning -BundleFile $path) {
        Say '  note: Vivaldi is running from this folder - the change takes effect after you restart it.' 'DarkYellow'
    }
    $action = if ($Revert) { 'revert' } else { 'apply' }
    if (-not $PSCmdlet.ShouldProcess($path, ($action + ' patch(es): ' + ($touched -join ', ')))) { return $code }

    $r = Save-Bundle -Path $path -OriginalBytes $bytes -NewText $text -MakeBackup (-not $Revert)
    if ($r -ne 0) { return [Math]::Max($code, $r) }
    $verb = if ($Revert) { 'Reverted' } else { 'Patched' }
    Say ('  {0}: {1}. Restart Vivaldi to use it.' -f $verb, ($touched -join ', ')) 'Green'
    Write-Log ('{0} {1}: {2} ({3})' -f $verb, $Target.Version, ($touched -join ', '), $path)
    return $code
}

# ---------------------------------------------------------------------------------------------------------
$exitCode = 0
$pendingAny = $false
try {
    if ($Status -and $Revert) { throw [System.ArgumentException]'Use either -Status or -Revert, not both.' }
    if ($Only) {
        $known = @($script:Patches | ForEach-Object { $_.Name })
        foreach ($o in $Only) {
            if ($known -notcontains $o) { throw [System.ArgumentException]("Unknown patch '$o'. Known patches: " + ($known -join ', ')) }
        }
    }
    $targets = @(Get-Targets)
    foreach ($t in $targets) {
        $r = Invoke-Bundle -Target $t
        if ($r -eq 10) { $pendingAny = $true }
        elseif ($r -gt $exitCode) { $exitCode = $r }
    }
    if ($exitCode -eq 0 -and $pendingAny) { $exitCode = 10 }
}
catch [System.IO.DirectoryNotFoundException], [System.IO.FileNotFoundException] {
    Say $_.Exception.Message 'Red'
    $exitCode = 3
}
catch {
    Say ('Error: ' + $_.Exception.Message) 'Red'
    $exitCode = 1
}
exit $exitCode
