# Vivaldi patches

Small fixes to Vivaldi's UI code for things settings and extensions cannot change.
Run from this folder; nothing here is inside `Application` or `User Data`, so `backup.bat` does not archive it.

| Patch | What it does |
|---|---|
| `no-follow` | "Move to Workspace" stays where you are instead of switching to the destination workspace |
| `fullscreen-hint` | The "Press Escape key to exit fullscreen." bubble is shown for 1 second (or never) instead of 4 seconds |

## Use

1. Close Vivaldi completely.
2. Run `Apply-VivaldiPatch.cmd` (double-click, or from a prompt). It applies every patch that is not applied yet.
3. Start Vivaldi.

| Option (pass to the `.cmd` or the `.ps1`) | Meaning |
|---|---|
| `-Status` | Read-only report per patch: PATCHED / NOT PATCHED (applies cleanly) / NOT APPLICABLE |
| `-WhatIf` | Show what would happen, change nothing |
| `-Revert` | Remove the patch(es) again (removes exactly the inserted text) |
| `-Only no-follow` / `-Only fullscreen-hint` | Work on one patch only |
| `-FullscreenHintMs 0` | Never show the fullscreen hint (default is `1000` = 1 second). Re-run with another value to change it |
| `-AllVersions` / `-Version 8.2.4133.80` | Patch every version folder / one specific folder (default: newest) |
| `-AppDir <path>` | The `Application` folder (default: found automatically) |
| `-BundlePath <file>` | Patch exactly this `bundle.js` |
| `-SkipSyntaxCheck` | Do not run the optional `node --check` first |

Exit codes: 0 ok, 1 a patch is not applicable / damaged markers (nothing changed for that patch), 2 verification
failed (original restored), 3 install not found, 4 cannot read/write the file (locked, read-only, no permission),
10 `-Status` only: nothing failed but something is not patched yet.

## After every Vivaldi update

An update installs a new `Application\<version>` folder, so the patches are gone. Close Vivaldi and run
`Apply-VivaldiPatch.cmd` again. `Apply-VivaldiPatch.cmd -Status` tells you where things stand.

## Patch: `no-follow` - "Move to Workspace" stays where you are

**Problem.** Since Vivaldi 8.0, moving the *active* tab to another workspace makes Vivaldi switch to that workspace
(and load it). Moving a background tab does not. Cause: the `tabs.onUpdated` listener in `bundle.js` calls
`setActiveWorkspace` when the active tab's workspace changes. There is no setting for it.

**Fix.** At the top of `moveToWorkspace` the script inserts one statement: if the active tab is among the tabs being
sent to a different workspace, first activate the tab Vivaldi would pick if that tab were closed (it honours your
"tab activation after closing" setting), or open a blank background tab if the workspace has no other tab. Then the
normal move runs. The moved tab is no longer active when the listener fires, so nothing follows it.

Covered: tab context menu > Move > Workspace, the "Move Selected Tabs to Workspace N" commands (keyboard / Quick
Commands), and "Create Workspace With This Tab" when created in the background.
Not covered: dragging tabs between workspaces in the Windows & Tabs panel (a different code path).
Applies to Vivaldi 8.0 and newer; older builds do not have the behaviour, so the script reports "not applicable".

## Patch: `fullscreen-hint` - shorter (or no) "Press Escape key to exit fullscreen." popup

**Problem.** Entering fullscreen (for example a video) shows a bubble for a hard-coded 4 seconds.

**Fix.** The shared bubble component (`XU` in 8.2) gets an optional per-use duration. Only the fullscreen hint
passes one (`-FullscreenHintMs`, default 1000, `0` = never shown). Toasts and the pointer-lock hint keep their
4 seconds. Clicking the bubble still dismisses it at once, and hovering over it keeps it open.
Applies to Vivaldi 7.8 and newer (checked on 7.8, 7.9, 8.0 and 8.2).

Alternative without patching: enable `vivaldi://flags/#vivaldi-css-mods`, point Settings > Appearance > Custom UI
Modifications at a folder and put `#browser.fullscreen .overlayinfobubble { display: none !important; }` in a `.css`
file there. That hides every bubble while the window is fullscreen (toasts and pointer-lock hint included).

## What it touches

Only `<Application>\<version>\resources\vivaldi\bundle.js`, plus a one-time copy of the original next to it as
`bundle.js.vivmod.bak` (it disappears with the version folder on the next update). Never `vivaldi.exe` or
`vivaldi.dll` (Widevine verifies those). Every inserted fragment is wrapped in `/*vivmod:<patch>:begin*/` ...
`/*vivmod:<patch>:end*/` markers, so `-Revert` removes exactly that text. Nothing is written unless every pattern of a
patch matches exactly once; the new file is syntax-checked with Node when `node` is on PATH, swapped in, read back and
compared, and the original bytes are restored if anything is off. Changes and failures are appended to `patch.log`.

## If it says NOT APPLICABLE

The script found nothing and changed nothing for that patch. Vivaldi probably changed that code (or fixed the
behaviour). The patterns live in the `Get-NoFollowPlan` / `Get-FullscreenHintPlan` functions at the top of
`Apply-VivaldiPatch.ps1` and need updating for the new build.

## Verify it works

Behaviour inside a running Vivaldi has not been verified yet (the script was tested on copies of the 7.8 to 8.2
bundles, including a check of the patched bubble component's timers). After applying and restarting:

- `no-follow`: in a workspace with at least two tabs, right-click the **active** tab > Move > pick another workspace.
  You should stay in the current workspace with another tab active; the moved tab is in the other workspace. Also try
  moving a background tab (unchanged) and the only tab of a workspace (a blank tab appears).
- `fullscreen-hint`: press F11 or fullscreen a video. The hint should disappear after about a second (plus the
  half-second fade). With `-FullscreenHintMs 0` it should not appear.

If anything looks wrong: `Apply-VivaldiPatch.cmd -Revert` (or `-Revert -Only <patch>`), restart Vivaldi.
