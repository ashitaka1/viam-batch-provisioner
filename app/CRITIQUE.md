# UX Critique

Three macOS UX critics reviewed the Flutter app on 2026-04-17, each with a
different lens. This document preserves their findings as a working punch list.

Severity scale used throughout:

- `BLOCKER` / `CRINGE` — embarrassing, broken, or actively traps the user
- `BAD` / `FRICTION` — clearly wrong, slows the user down
- `SMELLY` / `CONFUSING` — feels off, will eventually bite
- `NIT` — polish

File references use absolute project paths under
`/Users/avery.rosen/conductor/workspaces/viam-lab-provisioner/richmond/`.

---

## Cross-cutting themes

All three critics independently flagged the same root issues. These should
shape the order of work.

### The structural problem
The whole app is `CupertinoApp` — every widget is iPhone-shaped by design.
Action sheets slide up from the bottom, segmented controls are sliding pills,
modal routes take the full window, and there is no hover, no real menu bar,
no popovers, no settings window. The lasting fix is migration to `macos_ui`
plus an `NSMenuItem` → `FlutterMethodChannel` bridge so the menu bar can drive
in-app actions.

### Embarrassments fixable in minutes
- Menu bar literally reads "APP_NAME" (the Flutter scaffold default never
  replaced).
- Window has no `minSize` and no frame autosave; below ~600pt wide the layout
  collapses.
- `.SF Pro Text` / `.SF Mono` (private Apple font names) hardcoded across 8+
  files.
- `Cancel` buttons styled `isDestructiveAction: true` (red) — the opposite of
  HIG.

### Bugs disguised as UX issues
- **Cancel during flash does not kill `dd`** — the stream listener is
  cancelled but the underlying `flash-pi-sd.sh` keeps writing.
- **Reset's microcopy lies** — claims credentials are kept, actually deletes
  every MAC-keyed staging directory.
- **Sudo cancellation only marks dnsmasq as errored** — HTTP and watcher
  silently never start; no top-level signal.
- **Pi batches have no way to start the embedded HTTP server** — Boot stage
  isn't in the Pi flow at all.
- **Stage stepper completion is wrong** — Provision is always rendered green;
  Verify can never become green.

### Convergent complaints
- No keyboard support anywhere (Cmd+, , Return-to-submit, Esc-to-cancel, Tab
  order).
- No hover states or cursor changes on any list row.
- Stages are clickable when prerequisites aren't met (Flash before Provision).
- Prep buttons (Setup PXE / Build config) sit side-by-side with no ordering
  or gating.
- Reset / Clear are equal-weight buttons with only colour to distinguish the
  destructive one.

---

## Critic A — macOS interaction patterns

Lens: where iPhone-derived widgets are used in place of native macOS
patterns. Menu bar, window chrome, popovers vs action sheets, tooltips,
keyboard shortcuts, context menus, drag-and-drop.

1. **[CRINGE]** Menu bar literally says "APP_NAME" — placeholder text never replaced
   - File: `app/macos/Runner/Base.lproj/MainMenu.xib:25, 27, 29, 43, 61, 333`
   - The Apple menu, About, Hide, and Quit items all read "APP_NAME" verbatim. The window title bar shows "APP_NAME" too. This is the default Flutter scaffold; nobody did the find/replace.
   - Native macOS expectation: The application menu should read the app name (e.g. "Viam Provisioner"), and "About / Hide / Quit <Name>" should interpolate it.
   - Fix sketch: Replace `APP_NAME` with `Viam Provisioner` in `MainMenu.xib` (or wire a build-time substitution from `AppInfo.xcconfig`).

2. **[CRINGE]** Whole app is a `CupertinoApp` — every widget is iOS-shaped by design
   - File: `app/lib/app.dart:16`
   - `CupertinoApp` and the `Cupertino*` widget set are explicitly the iPhone/iPad design language: pill buttons, sliding segmented controls, action sheets, full-screen modal page routes, no hover/cursor affordances, no native menus.
   - Native macOS expectation: A desktop app should be built on `MaterialApp` plus `macos_ui` (`MacosWindow`, `Sidebar`, `PushButton`, `MacosPopupButton`, `MacosSearchField`, `Toolbar`, `MacosPopover`, etc.).
   - Fix sketch: Add `macos_ui` to `pubspec.yaml` and migrate the shell to `MacosApp` + `MacosWindow` + `MacosScaffold`.

3. **[CRINGE]** Environment switcher uses `CupertinoActionSheet` from the bottom — pure iPhone share-sheet behavior
   - File: `app/lib/features/shell/toolbar.dart:154-184`
   - `showCupertinoModalPopup` slides an action sheet up from the bottom edge of the window, complete with a destructive-styled "Cancel" button. On macOS this is a popover or pull-down menu attached to the chevron.
   - Native macOS expectation: A `MacosPopover` (macos_ui) anchored to the chevron, or an `NSMenu`-style pull-down via `MenuAnchor`/`PullDownButton`.
   - Fix sketch: Replace with `MacosPulldownButton`, or `MenuAnchor` + `MenuItemButton` so it lays out as a proper attached popover.

4. **[CRINGE]** No window minimum size — the entire UI collapses below ~600pt wide
   - File: `app/macos/Runner/MainFlutterWindow.swift:4-15`, `app/macos/Runner/Base.lproj/MainMenu.xib:334-336`
   - `MainFlutterWindow` never calls `self.minSize`, never sets `setFrameAutosaveName`, never marks the toolbar style. The shell hard-codes a 240pt sidebar plus a 320pt settings drawer plus an `Expanded` main panel with 24pt padding (`app_shell.dart:32-37`); resize the window narrow and the main panel goes negative.
   - Native macOS expectation: Every macOS window declares `minSize`, persists frame via `setFrameAutosaveName("MainWindow")`.
   - Fix sketch: In `MainFlutterWindow.awakeFromNib`, set `self.minSize = NSSize(width: 900, height: 600)` and `self.setFrameAutosaveName("MainWindow")`; clamp/scroll the shell row, or hide the sidebar at narrow widths.

5. **[CRINGE]** No real keyboard shortcuts — Cmd+, doesn't open Settings, Cmd+N doesn't make a batch, Cmd+R does nothing
   - File: `app/lib/app.dart` (no `Shortcuts`/`Actions` anywhere), `app/macos/Runner/Base.lproj/MainMenu.xib:36` (Preferences… menu item has no action selector wired)
   - The "Preferences…" menu item exists in the xib but has no `<connections>` block, so Cmd+, is a no-op. There is no `Shortcuts(...)` widget in the Flutter tree. There is no method-channel bridge between the menu bar and the Flutter side.
   - Native macOS expectation: Cmd+, opens Settings; Cmd+N creates the primary new object; Cmd+R reloads/refreshes the active panel; Cmd+1/2/3 jump between sidebar stages.
   - Fix sketch: Wrap the shell in `Shortcuts`/`Actions` for in-app accelerators, and add an `NSMenuItem` → `FlutterMethodChannel` bridge in `MainFlutterWindow`.

6. **[CRINGE]** Settings is a hand-rolled in-window pane, not a real Settings window
   - File: `app/lib/features/shell/app_shell.dart:35-38`, `app/lib/features/settings/settings_drawer.dart:1-46`
   - "Settings" toggles a 320pt-wide right-hand drawer that shoves the main content sideways. Mac users expect Settings to be a separate, smaller, modeless `NSWindow` opened by Cmd+,.
   - Native macOS expectation: A separate Preferences/Settings window with toolbar tabs.
   - Fix sketch: Use `desktop_multi_window` (or `macos_ui`'s settings pattern) to spawn a second window; keep the drawer only for in-context inspectors.

7. **[CRINGE]** "Cancel" button styled red/destructive in dialogs and action sheets
   - File: `app/lib/features/shell/toolbar.dart:177-181`, `app/lib/features/settings/settings_drawer.dart:243-247`
   - `isDestructiveAction: true` on Cancel makes the button red. Cancel is *never* destructive. The destructive option in a confirmation dialog is the action being confirmed.
   - Native macOS expectation: Cancel is plain; the destructive action is red and on the right (or trailing); the safe default is bordered/blue.
   - Fix sketch: Remove `isDestructiveAction` from every Cancel; apply it only to the actual destructive action.

8. **[BAD]** Wrong button order in `CupertinoAlertDialog`s — vertical iPhone-style stacked buttons, not horizontal NSAlert layout
   - File: `app/lib/features/shell/sidebar.dart:113-128`, `app/lib/features/settings/settings_drawer.dart:351-374`
   - Stacked `CupertinoDialogAction`s are vertically split iPhone-style alerts, not the horizontal NSAlert layout with proper key-equivalents (Return = default, Esc = Cancel).
   - Native macOS expectation: A `MacosAlertDialog` or `AlertDialog.adaptive` with horizontal action row, default button bound to Return, Cancel bound to Esc.
   - Fix sketch: Replace `CupertinoAlertDialog` with `MacosAlertDialog` and let `Shortcuts(LogicalKeyboardKey.escape)` map to Cancel.

9. **[BAD]** Sidebar list rows are bare `GestureDetector`s — no hover state, no cursor change, no right-click menu
   - File: `app/lib/features/shell/sidebar.dart` (whole file), `app/lib/features/batch/sidebar_batch.dart:91`, `app/lib/features/settings/settings_drawer.dart:284`
   - Zero `MouseRegion`, zero hover highlight, no `SystemMouseCursors.click`, no `onSecondaryTap` for context menus.
   - Native macOS expectation: Hover-highlight rows, cursor change to click cursor over interactive elements, right-click menu (Rename / Duplicate / Delete environment; Reset / Clear / Open in Finder for the batch).
   - Fix sketch: Wrap row contents in `MouseRegion(cursor: SystemMouseCursors.click)` plus a hover-tracked highlight; add `MenuAnchor` for secondary tap.

10. **[BAD]** `CupertinoSlidingSegmentedControl` for theme + provisioning mode — that's the iPhone Messages bubble control
    - File: `app/lib/features/settings/settings_drawer.dart:68-88`, `app/lib/features/settings/environment_form.dart:196-217`
    - The sliding pill is unmistakably iOS. On macOS the equivalent is `NSSegmentedControl` (flat, separated buttons), or for mutually-exclusive choices, `NSPopUpButton` or radio group.
    - Native macOS expectation: `MacosSegmentedControl` for short option sets, `MacosPopupButton` for 3+ values, or a vertical radio group with helper text per mode.
    - Fix sketch: Swap to `MacosSegmentedControl` for theme; use `MacosPopupButton<String>` for `_provisionMode` so each option can have a tooltip.

11. **[BAD]** Environment form opens via `CupertinoPageRoute` as a full-screen iPhone navigation push
    - File: `app/lib/features/settings/environment_form.dart:108-124`, `settings_drawer.dart:265-269, 322-326`
    - Editing an environment pushes a full-screen `CupertinoPageScaffold` with a `CupertinoNavigationBar` (back-arrow + title + trailing "Save"). That's the iPhone navigation pattern.
    - Native macOS expectation: A sheet attached to the parent window or a separate window, with OK/Cancel in the bottom-trailing corner.
    - Fix sketch: Replace `CupertinoPageRoute` with `showMacosSheet` (or a constrained `Dialog` ~520pt wide) and move Save/Cancel to a bottom button bar.

12. **[BAD]** Toolbar uses Flutter's container-with-border instead of a real macOS titlebar/toolbar
    - File: `app/lib/features/shell/app_shell.dart:25-44`, `app/lib/features/shell/toolbar.dart:20-28` (52pt `Container`), `MainMenu.xib:333-341` (no `titlebarAppearsTransparent`, no `fullSizeContentView`, no `NSWindowToolbar`)
    - The native title bar sits empty above a 52pt fake toolbar, eating ~80pt of vertical space. The fake toolbar is also not a window-drag region.
    - Native macOS expectation: Unified titlebar+toolbar (`titlebarAppearsTransparent + fullSizeContentView`) with the env picker as a toolbar item next to the traffic lights.
    - Fix sketch: In `MainFlutterWindow`, set `self.titlebarAppearsTransparent = true; self.styleMask.insert(.fullSizeContentView)`; in Flutter, use `macos_ui`'s `ToolBar` (or wrap the bar in `DragToMoveArea`).

13. **[BAD]** Logs are vanilla `ListView`s — no selection, no copy, no search, iOS bouncy scroll
    - File: `app/lib/features/batch/provision_stage_panel.dart:181-202`, `app/lib/features/boot/boot_stage_panel.dart:439-471`, `app/lib/features/flash/flash_stage_panel.dart:509-526`
    - You can't select a line, can't Cmd+C a chunk, can't Cmd+F to find an error. Boot panel has a single "Copy" button that copies *everything* — useless when you want to grab one error. Default scroll physics under `CupertinoApp` is `BouncingScrollPhysics`.
    - Native macOS expectation: Selectable, copyable text with a context menu and Cmd+F find. Overlay (non-bouncy) scrollbars.
    - Fix sketch: Wrap each log in `SelectionArea`, set `physics: const ClampingScrollPhysics()`, add `Scrollbar(thumbVisibility: true)`.

14. **[BAD]** Tooltips only on three items, with iOS-flavored 500ms delay
    - File: `app/lib/features/shell/toolbar.dart:2, 88-103, 129-152`
    - Only the gear icon and three service indicators have tooltips; the env chevron, sidebar rows, edit/trash icons, prep buttons — all unlabeled.
    - Native macOS expectation: Every icon-only button has a tooltip; tooltips appear after the system delay (~1s).
    - Fix sketch: Add `Tooltip`s to every icon-only button; standardize the delay via theme.

15. **[SMELLY]** Hard-coded `.SF Mono` / `.SF Pro Text` font family strings — private Apple system font names
    - File: `app/lib/theme/theme.dart:14-19`; `sidebar_batch.dart:214`; `provision_stage_panel.dart:191`; `boot_stage_panel.dart:451, 459`; `flash_stage_panel.dart:518`; `verify_stage_panel.dart:218`; `settings_drawer.dart:123`; `new_batch_form.dart:149`
    - The leading dot is the *private* Apple system font name; brittle across macOS versions and absent on Linux/Windows.
    - Native macOS expectation: Use `CupertinoTheme.of(context).textTheme` for default font; for monospace, ship JetBrains Mono or use Menlo as fallback.
    - Fix sketch: Drop the literal strings; for monospace use `TextStyle(fontFamilyFallback: const ['Menlo', 'Monaco', 'Courier New'])`.

16. **[SMELLY]** No drag-and-drop — for SD-card flashing, env import, or SSH key selection
    - File: `app/lib/features/flash/flash_stage_panel.dart:114-183` (no `DropTarget`)
    - Flashing an SD card on macOS naturally invites drag-and-drop ("drop a card here" or drop a `.img` file). Nothing in this app reacts to drag.
    - Native macOS expectation: `desktop_drop`/`super_drag_and_drop` widgets receive files; the SSH key field could accept a dropped `.pub`.
    - Fix sketch: Add `desktop_drop` to dependencies and wrap the SSH-key field and the env section in `DropTarget`.

17. **[SMELLY]** Focus traversal unconfigured in env form — no `FocusTraversalGroup`, Return doesn't save
    - File: `app/lib/features/settings/environment_form.dart:174-194`
    - Tab moves through fields, but Return/Enter inside the WiFi password field does nothing — desktop users expect it to save.
    - Native macOS expectation: Tab cycles fields, Return triggers the default button, Esc cancels.
    - Fix sketch: Wrap the form in `FocusTraversalGroup`; set `onSubmitted: (_) => _save()` on the last field; add a `Shortcuts(LogicalKeyboardKey.enter → ActivateIntent)`.

18. **[SMELLY]** Trash / pencil / plus icons have no `Semantics` labels — unusable with VoiceOver
    - File: `app/lib/features/settings/settings_drawer.dart:178-184, 318-344`, `toolbar.dart:91-103`
    - Each is a `CupertinoButton(child: Icon(...))` with no `semanticLabel` on the Icon and no `Semantics` wrapper. VoiceOver will read "button" with no name.
    - Native macOS expectation: Every interactive icon has an accessibility label matching its tooltip.
    - Fix sketch: Pass `semanticLabel:` to every `Icon`, or wrap each button in `Semantics(label: ..., button: true)`.

19. **[NIT]** "Reset" / "Clear" buttons in sidebar are full-width pill `CupertinoButton`s with hardcoded colors
    - File: `app/lib/features/shell/sidebar.dart:140-176`
    - `CupertinoButton` with `color: CupertinoColors.systemGrey5` and `borderRadius: 8` is the iOS rounded-rect button. Macs use a flat `PushButton` and would put destructive Clear in red text only.
    - Native macOS expectation: `PushButton` right-aligned in a footer; destructive Clear visually subdued, with the confirm dialog doing the warning.
    - Fix sketch: Swap for `macos_ui` `PushButton(buttonSize: PushButtonSize.large, secondary: true)` and `PushButton(... color: MacosColors.systemRedColor)` for Clear.

20. **[NIT]** Sidebar isn't a real macOS sidebar — opaque `Container`, no vibrancy, no resize divider
    - File: `app/lib/features/shell/app_shell.dart:32`, `app/lib/features/shell/sidebar.dart:22-23`
    - 240pt opaque `Container` colored with `barBackgroundColor`. macOS sidebars in modern apps are translucent, materially-blurred, and visually distinct from the content area.
    - Native macOS expectation: `MacosWindow` with `Sidebar(builder: ..., minWidth: 220)` gives native vibrancy + collapsibility + draggable resize divider.
    - Fix sketch: Adopt `macos_ui`'s `MacosWindow`/`Sidebar`.

---

## Critic B — visual polish, typography, density, color

Lens: where Cupertino defaults look chunky, mis-sized, or tonally off on
macOS.

1. **[CRINGE]** Global body font is iOS-sized (14pt) instead of macOS body (13pt)
   - File: `app/lib/theme/theme.dart:16`
   - `fontSize: 14` is the iOS Cupertino default; macOS HIG body is 13pt, sidebars/captions go to 11pt. The theme defines no caption/headline/title styles at all, so every widget below invents its own size by hand. There's no type system.
   - Native macOS expectation: HIG type stack — Title 1 (28), Title 2 (22), Title 3 (17), Headline (13 semibold), Body (13), Subhead (11), Caption (10). System font is `.AppleSystemUIFont`.
   - Fix sketch: Replace the theme with a real `CupertinoTextThemeData` setting `textStyle` (13), `actionTextStyle` (13), `tabLabelTextStyle` (10), `navTitleTextStyle` (13 semibold), `navLargeTitleTextStyle` (22). Remove per-widget `fontSize:` literals.

2. **[CRINGE]** Hard-coded grays for dark mode break system contrast and ignore accent color
   - File: `app/lib/theme/theme.dart:9-12, 17`
   - `scaffoldBackgroundColor: Color(0xFF1E1E1E)`, `barBackgroundColor: Color(0xFF2D2D2D)`, text color `CupertinoColors.white`/`black`. None dynamic — they ignore desktop translucency, the user's accent color, increased-contrast mode, and elevated/base material distinctions.
   - Native macOS expectation: macOS surfaces use `windowBackgroundColor`, `controlBackgroundColor`, `underPageBackgroundColor` — all `CupertinoDynamicColor`s.
   - Fix sketch: Use `CupertinoColors.systemBackground` and `CupertinoColors.secondarySystemBackground` (or `tertiarySystemBackground` for sidebars); let `label` resolve text color.

3. **[CRINGE]** Toolbar is 52pt — desktop macOS toolbars are ~38pt
   - File: `app/lib/features/shell/toolbar.dart:21`
   - `height: 52` is Cupertino nav-bar height tuned for a thumb on iPhone. On a 900px window that's 5.8% of vertical real estate spent on a strip with one dropdown and three dots. Combine with the macOS title bar and you've burned ~75pt of chrome.
   - Native macOS expectation: Standard NSToolbar is 38pt (small) or 52pt only when "Icon and Text" is explicitly chosen.
   - Fix sketch: Set `height: 38`, drop icon sizes by 2pt, drop the env dropdown text to 13.

4. **[CRINGE]** Settings gear is 22pt — that's an iPad icon
   - File: `app/lib/features/shell/toolbar.dart:100`
   - `Icon(... size: 22)` for the gear in a toolbar where the document icon is 16pt and the chevron is 12pt — three different scales jammed into one row, with the gear visually dominant for no reason.
   - Native macOS expectation: SF Symbols at "small" weight, ~15pt, for toolbar items.
   - Fix sketch: `size: 16` for the gear, match the doc icon.

5. **[BAD]** Sidebar isn't a sidebar — no vibrancy, no inset selection, identical background to toolbar
   - Files: `app/lib/features/shell/app_shell.dart:32`, `sidebar.dart:23`, `sidebar_batch.dart:89, 96-97`
   - 240pt fixed width is fine, but the sidebar uses `barBackgroundColor` (same as toolbar — no visual separation) and selected rows get `systemBlue.withValues(alpha: 0.12)` filling the row to the edge. Native macOS sidebars use translucent material with rounded inset selection capsules. No hover state at all.
   - Native macOS expectation: `NSVisualEffectView .sidebar` material; selection is an inset rounded rectangle in `controlAccentColor`.
   - Fix sketch: Tint the sidebar bg (`secondarySystemBackground.resolveFrom(context)`), add `MouseRegion` hover, inset selection with `margin: EdgeInsets.symmetric(horizontal: 8, vertical: 1)` + `borderRadius: 6`.

6. **[BAD]** Stage stepper has no real stepper visual — same green check icon for stage AND machine rows
   - File: `app/lib/features/batch/sidebar_batch.dart:99-114, 192-199`
   - Despite "1. Provision / 2. Flash / 3. Verify" labels there is no stepper affordance — no line connecting steps, no current/done/upcoming distinction beyond green check vs empty circle. Same `checkmark_circle_fill` for stage completion AND per-machine completion, so the eye can't tell stage-state from instance-state.
   - Native macOS expectation: A stepper either uses numbered nodes with connectors (Setup Assistant style) or is a plain source-list group — not both.
   - Fix sketch: Either commit to a real stepper (vertical 1pt line behind small circles with numbers), or drop the stepper pretense and style stages as a source-list group with trailing count badges.

7. **[BAD]** "Reset" / "Clear" pill buttons at sidebar footer are oversized iOS pills with hardcoded white text
   - File: `app/lib/features/shell/sidebar.dart:142-172`
   - `CupertinoButton(color: …, borderRadius: 8, padding: vertical: 8)`, only filled buttons in the sidebar, eat ~50pt vertical, "Clear" is full-saturation `destructiveRed`. Hardcoded `CupertinoColors.white` won't auto-adapt.
   - Native macOS expectation: Sidebar destructive actions live in a context menu or a tertiary text button.
   - Fix sketch: Move both into a "•••" overflow menu, or use unfilled `CupertinoButton` with `destructiveRed` text only.

8. **[BAD]** Dropdown chevron is a "scroll down" arrow, not a "popup menu" disclosure
   - File: `app/lib/features/shell/toolbar.dart:58-59`
   - `chevron_down` reads as "scroll down" rather than "open menu." macOS popup buttons use a chevron-up-chevron-down disclosure glyph.
   - Native macOS expectation: `NSPopUpButton` uses a small "⌄⌃" pair, or `chevron.up.chevron.down`.
   - Fix sketch: Replace with `CupertinoIcons.chevron_up_chevron_down`.

9. **[BAD]** Tonal contrast inversion — section header dimmer than per-row data
   - File: `app/lib/features/batch/sidebar_batch.dart:166-173, 150-153`
   - "Machines" header is `tertiaryLabel`; per-row "1/1" counts are `secondaryLabel`. Hierarchy reads backwards.
   - Native macOS expectation: Source list group headers are `secondaryLabel` ALL CAPS at 11pt; counts/badges go to `tertiaryLabel` or a pill.
   - Fix sketch: Swap: header → `secondaryLabel` semibold uppercase; row counts → `tertiaryLabel`.

10. **[BAD]** Manual numeric prefixes ("1. Provision") concatenated into label strings
    - File: `app/lib/features/batch/sidebar_batch.dart:104`
    - `'${index + 1}. ${stage.label}'` — a real stepper has the index in a separate visual node (numbered circle), not concatenated. Also breaks localization.
    - Native macOS expectation: Numbers, when shown, are part of the leading icon/badge.
    - Fix sketch: Drop the number from the string; put it inside the leading circle when not yet complete.

11. **[BAD]** Service status dot 8pt is invisible at typical viewing distance; label vanishes
    - File: `app/lib/features/shell/toolbar.dart:135-148`
    - 8pt dots in `secondaryLabel` 11pt next to 14pt body produces a "did the dot disappear?" effect. Stopped state uses `systemGrey3`, nearly invisible on light. No border, no glow on running, no chip background.
    - Native macOS expectation: Status pills (Xcode/Simulator/Time Machine) use a 9–10pt disc with a thin contrast ring.
    - Fix sketch: 9pt dot + 0.5pt outline (`color.withOpacity(0.4)`), label color → `label`, drop fontSize to 12 with `FontWeight.w500`.

12. **[BAD]** `CupertinoButton.filled` in flash/boot/verify uses `padding: horizontal: 24, vertical: 10` — Big iPad pills
    - Files: `app/lib/features/boot/boot_stage_panel.dart:46-47`, `flash_stage_panel.dart:288, 379, 431`
    - A single primary action takes ~140×38pt of saturated blue. Adjacent secondary `CupertinoButton`s have NO padding override so the implicit padding differs — primary and secondary in the same row have mismatched heights and corner radii.
    - Native macOS expectation: Push buttons are 22pt tall (small) or 28pt (regular), ~12pt horizontal padding, accent-colored.
    - Fix sketch: Define `_primaryButton`/`_secondaryButton` helpers with consistent `padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6)` and `borderRadius: 6`.

13. **[BAD]** Stage panel headers are oversized (20pt semibold + 13pt subtitle + 22pt icon)
    - Files: `app/lib/features/boot/boot_stage_panel.dart:111-113`, `flash_stage_panel.dart:96`, `verify_stage_panel.dart:73`, `provision_stage_panel.dart:101-104`
    - Every stage panel opens with a 20pt semibold headline + 13pt subtitle stack. On a 900px window with one stage visible, this header eats 50pt and competes with the toolbar/title bar above. The 22pt status icon is also too big.
    - Native macOS expectation: Settings-style panels use 17pt semibold or skip it (rely on window title / sidebar selection for context).
    - Fix sketch: Drop to 15–17pt regular, drop the 22pt leading icon to 16pt or remove it, tighten subtitle to 12pt.

14. **[SMELLY]** Selection background uses `systemBlue` (fixed) instead of `controlAccentColor`
    - Files: `sidebar_batch.dart:89`, `settings_drawer.dart:294, 306`, `flash_stage_panel.dart:87`
    - Hard-coded `CupertinoColors.systemBlue` / `activeBlue`. Users with Accent Color = Pink/Graphite get surprise blue everywhere.
    - Native macOS expectation: Controls inherit the user's accent color; Flutter macOS exposes via `system_theme` or platform channel.
    - Fix sketch: Replace literal blues with `CupertinoTheme.of(context).primaryColor`; or pull system accent via `system_theme`.

15. **[SMELLY]** Hardcoded 14pt for env name in toolbar; "doc_text" icon implies "document", not "environment"
    - File: `app/lib/features/shell/toolbar.dart:32, 47-48`
    - `CupertinoIcons.doc_text` next to an environment name suggests "document". And `fontSize: 14` is hardcoded inline rather than coming from `actionTextStyle`.
    - Native macOS expectation: Toolbar items use SF Symbols semantically meaningful for the action.
    - Fix sketch: Switch icon to `CupertinoIcons.cube_box` or `folder`; drop the explicit fontSize, inherit from theme.

16. **[SMELLY]** Top-aligned icon padding hacks (`top: 2`, `top: 4`) reveal baseline misalignment
    - Files: `boot_stage_panel.dart:86`, `verify_stage_panel.dart:53`, `provision_stage_panel.dart:45, 51-52, 65-66, 75-76`
    - Multiple `Padding(padding: EdgeInsets.only(right: 10, top: 2))` and `top: 4` micro-shifts are evidence the icon-text rows aren't using a baseline-aligned layout.
    - Native macOS expectation: Toolbar/header icon-with-text uses a Row with `crossAxisAlignment: center` and a properly-sized icon (cap-height ≈ font cap-height).
    - Fix sketch: Drop the `top: N` overrides; size icons to ~1.4× line cap-height; let center alignment do the work.

17. **[SMELLY]** Column dividers are 1pt instead of macOS 0.5pt hairlines
    - File: `app/lib/features/shell/app_shell.dart:33, 36`
    - macOS hairlines are 0.5pt (CSS `1px / devicePixelRatio`). 1pt looks heavy on Retina. The sidebar uses 0.5pt elsewhere — consistency broken.
    - Native macOS expectation: 0.5pt `separator` (which already adapts).
    - Fix sketch: `Container(width: 0.5, color: CupertinoColors.separator)`.

18. **[SMELLY]** No focus rings, no hover states, no keyboard affordance anywhere
    - Files: `sidebar_batch.dart:91-93`, `settings_drawer.dart:284`, `sidebar.dart` machine rows
    - Sidebar rows and tiles use `GestureDetector` — no `MouseRegion`, no `Focus`, no `Shortcuts`. Tabbing won't show a focus halo. Hovering shows nothing.
    - Native macOS expectation: All interactive controls have hover (subtle bg change), focus (1.5pt accent ring), pressed states.
    - Fix sketch: Replace `GestureDetector` with `_SidebarRow` wrapping `MouseRegion` + `FocusableActionDetector`; add focus ring via `decoration.border` when `isFocused`.

19. **[NIT]** Empty states are present but bland — no illustration, no CTA
    - Files: `boot_stage_panel.dart:362-386`, `provision_stage_panel.dart:157-171`, `flash_stage_panel.dart:480-500`
    - Three different empty-state implementations, all just an icon + small caption. None offer the user a next action.
    - Native macOS expectation: macOS empty states (Mail, Messages) center an SF Symbol at 40pt + Title 3 + Subhead + a primary action button.
    - Fix sketch: Extract one `_EmptyState({icon, title, subtitle, primaryAction})` widget; reuse everywhere; always offer the obvious next action.

20. **[NIT]** Settings drawer is 320pt slide-over instead of a macOS preferences sheet/window
    - File: `app/lib/features/shell/app_shell.dart:35-38`
    - macOS apps do Settings in a separate window (Cmd+,), not a side drawer that compresses content. The drawer also has no slide animation.
    - Native macOS expectation: `NSWindow` with toolbar tabs (General / Environments / Network), opened by Cmd+,.
    - Fix sketch: Move to a separate native window, or at minimum animate the drawer slide-in over 200ms.

---

## Critic C — workflow, discoverability, microcopy

Lens: where users get confused, lost, blocked, or frustrated tracing real
workflows.

1. **[BLOCKER]** First-launch user dumped into "No environment selected" with no in-screen call to action
   - File: `app/lib/features/shell/app_shell.dart:75-103`
   - Net-new user opens the app, sees "Open Settings to create or select an environment", has to mentally map "Settings" to the gear in the upper-right, click it, then notice a tiny `+` next to "Environments" inside the drawer to even start. No button on the empty state itself.
   - Expected: A primary "Create environment" button in the empty state.
   - Fix sketch: Add a `CupertinoButton.filled` in `_NoEnvironment` that calls the same `_showCreateDialog` flow.

2. **[BLOCKER]** "Create environment" dialog asks only for a name, then blasts user with a 13-field form with no explanation
   - File: `app/lib/features/settings/settings_drawer.dart:228-261`, `app/lib/features/settings/environment_form.dart:107-158`
   - Operator types name, hits Create, gets OS Account / Network / SSH / Viam Cloud / Tailscale fields with zero copy. SSH key path defaults to `~/.ssh/id_ed25519.pub` with no "Browse" button. Username/password defaults to `viam`/`checkmate` silently — security footgun.
   - Expected: A wizard with sectional explanations and a "Browse" picker for the SSH key, or one-liner above each section.
   - Fix sketch: Add helper text under each section header, add file-picker button beside the SSH key field, require explicit confirmation that defaulted credentials are intentional.

3. **[BLOCKER]** Environment form has no validation, no error feedback, no Cancel button
   - File: `app/lib/features/settings/environment_form.dart:85-105, 116-124`
   - User leaves Username blank → `_save()` writes empty values, sets that env active, pops with no error. Provision mode = "full" + empty Viam fields → silently saved. Pressing back chevron or Cmd+W loses everything with no confirm. Save also force-activates the just-edited env, surprising when editing a non-active one.
   - Expected: Inline validation, Cancel + dirty-state guard, only set-active on first creation.
   - Fix sketch: Add `_validate()` before save, show inline errors, add explicit Cancel that confirms when dirty.

4. **[BLOCKER]** Stages clickable even when prerequisites aren't met
   - File: `app/lib/features/batch/sidebar_batch.dart:91-116`
   - `GestureDetector` always switches `selectedStageIndexProvider` regardless of whether previous stage actually completed. User can click "Verify" before "Provision" finished and see a mostly-empty table; can click "Flash" before any provisioning.
   - Expected: Disabled (greyed out) stages until prerequisites pass, with tooltip explaining what's missing.
   - Fix sketch: Compute `enabled` per stage; render a non-tappable, dimmed `_StageRow` when not enabled; tooltip "Complete Provision first."

5. **[BLOCKER]** New Batch form is the entire main panel — no breadcrumb back, no Cancel, env switch silently changes context
   - File: `app/lib/features/shell/app_shell.dart:60`, `app/lib/features/batch/new_batch_form.dart`
   - User starts typing prefix/count, opens drawer to fix something, comes back — controllers persist (good), but if they switch envs the form's provision mode silently changes underneath them. Only way out is to fill it and click Create.
   - Expected: Cancel button, persistent header showing where they are, guard against env switches during in-flight form input.
   - Fix sketch: Wrap form in a panel with header; add Cancel; reload provision mode label with an info banner if env changed.

6. **[BLOCKER]** Sidebar Reset and Clear sit side-by-side, similar widths, only colour distinguishes them — easy to mis-click and nuke a real batch
   - File: `app/lib/features/shell/sidebar.dart:131-176`
   - Reset (grey) and Clear (red) are equal-weight `Expanded` buttons. The Clear confirmation says "This cannot be undone" but does *not* require typing the batch name. After accidental click, the entire batch (queue.json, batch.json, slot dirs, MAC dirs) is erased.
   - Expected: Destructive action visually de-emphasized (or in overflow menu) and require typing the batch name to confirm.
   - Fix sketch: Move Clear into a `…` menu, or require typed-name confirmation modal.

7. **[BLOCKER]** Service health dots have tooltips but no `onTap` — spec promised "Clickable to expand start/stop controls"
   - File: `app/lib/features/shell/toolbar.dart:109-152`, `APP_SPEC.md:93-94`
   - User sees red dot for DHCP, hovers → "error". Clicks expecting a popover with Restart — nothing happens. Discovering that start/stop only lives in the Boot stage requires creating an x86 batch first (Pi batches don't include the Boot stage at all per `Batch.stages`). Pi-batch users have *no UI* to start the embedded HTTP server.
   - Expected: Click dot → popover with start/stop/restart/log link.
   - Fix sketch: Wrap indicator in `CupertinoButton` opening a small popover; or surface the Boot/Services panel even from Pi batches.

8. **[BLOCKER]** When sudo is cancelled, only dnsmasq tile shows the error — HTTP and watcher silently stay stopped
   - File: `app/lib/providers/service_providers.dart:40-54`
   - User clicks Start Services, macOS dialog appears, hits Cancel. Function early-returns after writing only `dnsmasq.error = "Sudo authentication cancelled"`. HTTP never starts, watcher never starts, but their dots remain grey "stopped". Boot header still shows "PXE services stopped" with no banner saying *why*.
   - Expected: A banner explaining cancellation, all-or-nothing behavior or clearer per-service state.
   - Fix sketch: Surface a banner above `_PrepRow` whenever any service has `state == error`; make the start flow surface sudo-cancelled as a global error.

9. **[FRICTION]** Stage stepper completion logic is wrong — Provision always shown complete, Verify never
   - File: `app/lib/features/batch/sidebar_batch.dart:129-137`
   - `_stageComplete` returns `true` for `BatchStage.provision` regardless of whether `provision-batch.sh` ran. Verify is hard-coded to `false` so it can never light up green even when all machines are flashed.
   - Expected: Provision should reflect actual session success or non-empty queue with credentials; Verify should turn green when `assignedCount == count`.
   - Fix sketch: Tie Provision completion to a real check; tie Verify to `batch.assignedCount == batch.count`.

10. **[FRICTION]** Provision panel after externally-created batch shows bare header + empty log — no CTA
    - File: `app/lib/features/batch/provision_stage_panel.dart:72-89`, `app_shell.dart:60-67`
    - When a batch was created via CLI (or earlier session), `session.hasRun` is false and `batch != null`, so the header shows "Batch: test-pre / 1 machine" with an empty grey "No output yet." box. No "Re-provision", "Stage credentials", or "What next?" — user is staring at near-blank panel wondering what to do.
    - Expected: A CTA card: "Provisioning was completed externally. View next steps →" or a "Re-stage credentials" button.
    - Fix sketch: When `batch != null && !session.hasRun`, show CTA card with "Continue to Flash / Boot" and optional "Re-provision" secondary.

11. **[FRICTION]** Boot stage prep buttons "Setup PXE" and "Build config" don't communicate ordering, dependencies, or what they do
    - File: `app/lib/features/boot/boot_stage_panel.dart:132-190`
    - Side by side, identical styling. Only hint is one tiny line. No arrow or numbering, no disabling of "Build config" until "Setup PXE" is done. User might click "Build config" first and get a cryptic shell-script error. No "View log details" affordance for `prep.lastError`.
    - Expected: Numbered `1.` and `2.`, second disabled until first is green, tooltip explaining each, clearer error reporting.
    - Fix sketch: Number the buttons; gate `_PrepButton(buildConfig)` on `prepDoneProvider(setupPxe)`; surface `prep.lastError`.

12. **[FRICTION]** Flash wizard "Cancel" during `flashing` does NOT kill the underlying `dd`
    - File: `app/lib/providers/flash_providers.dart:127-132`
    - User clicks Cancel mid-flash. UI returns to idle, but `flash-pi-sd.sh` keeps writing. No confirmation — Cancel is right next to the activity indicator.
    - Expected: Cancel during flashing should warn ("Flash in progress — stopping may corrupt the card. Continue?") then SIGTERM the process. Or at minimum disable the button.
    - Fix sketch: Capture the `Process` in `runProcess`, kill it on cancel; add destructive styling and confirmation when phase == flashing.

13. **[FRICTION]** "Insert SD card" auto-detect picks `newOnes.first` with zero disambiguation when two new disks appear
    - File: `app/lib/providers/flash_providers.dart:36-49, 53-65`
    - User plugs in two SD cards in quick succession (common for batches). One gets auto-selected, the other ignored. Worst case: a user's external backup drive gets `dd`'d.
    - Expected: When `newOnes.length > 1`, show a chooser. Always show device size and a final "you sure?" with the device name they can compare to System Information.
    - Fix sketch: Render a list when multiple new disks; require typed confirmation when size > 64GB (likely not an SD card).

14. **[FRICTION]** No keyboard support: Esc doesn't dismiss dialogs, Return doesn't submit forms, Tab order unreviewed
    - File: `app/lib/features/batch/new_batch_form.dart:91-114`, `settings_drawer.dart:230-260`
    - User hits Return after the count field expecting submission — nothing. In "New Environment" name dialog, Esc doesn't cancel. Cmd+W closes the entire window with no "unsaved changes" guard.
    - Expected: Standard macOS form-keyboard behavior.
    - Fix sketch: Wire `onSubmitted` to `_create`/dialog primary action; add `Shortcuts`/`Actions` for Escape; intercept window close.

15. **[FRICTION]** Environment switcher has no confirmation and instantly re-symlinks `config/site.env` even mid-flash or mid-provision
    - File: `app/lib/features/shell/toolbar.dart:154-184`, `settings_drawer.dart:284-289`
    - User can click an env in the toolbar action sheet (or a tile in the drawer) while `dd` is running or `provision-batch.sh` is mid-flight. Switch happens instantly; scripts reading site.env mid-execution get inconsistent state. No warning. No hover state on tiles.
    - Expected: Confirmation when an operation is running; visual hover state on tiles; "Switching to X…" toast.
    - Fix sketch: Block env switch when `provisionController.isRunning || flashController.phase != idle || services.anyRunning`.

16. **[FRICTION]** Network section in Settings drawer is read-only — no NIC selector, despite spec promising one
    - File: `app/lib/features/settings/settings_drawer.dart:95-154`, `APP_SPEC.md:120-124`
    - Drawer just lists "en0 · en1 · en6" with "Default: en6". No dropdown, no save, no override. Multi-NIC operators have no GUI control over which interface PXE serves.
    - Expected: A picker with selection persisted into `dnsmasq.conf` generation.
    - Fix sketch: Replace labels with `CupertinoPicker`/`showCupertinoModalPopup`; wire selection into dnsmasq launch args.

17. **[CONFUSING]** Reset's microcopy lies — says "Staged credentials are kept" but `_resetBatch` deletes every MAC-keyed directory
    - File: `app/lib/features/shell/sidebar.dart:43-77`
    - Dialog promises "the same batch can be re-flashed" with credentials kept, but the implementation walks `repo.machinesDir` and deletes every `^[0-9a-f]{2}:` directory — those are the per-machine credential payloads. After Reset, next PXE assignment finds no credentials.
    - Expected: Either keep credentials as advertised, or accurately say "MAC assignments cleared; re-provision required."
    - Fix sketch: Either preserve those dirs, or change copy.

18. **[CONFUSING]** "PXE prep" wrench card sits between header and service list with no visual sectioning — operators don't realise prep must come first
    - File: `app/lib/features/boot/boot_stage_panel.dart:24-43`
    - New user lands on Boot stage, sees Start Services prominently, clicks it. dnsmasq fires, but `setup-pxe-server.sh` never ran so `netboot/grubx64.efi` doesn't exist — first PXE boot fails mysteriously.
    - Expected: Start Services disabled with tooltip "Run Setup PXE and Build config first" until both prep checks pass.
    - Fix sketch: Gate the Start Services button on `prepDoneProvider(setupPxe).valueOrNull == true && prepDoneProvider(buildConfig).valueOrNull == true`.

19. **[CONFUSING]** Services log is shared across HTTP / dnsmasq / watcher / setup / build-config with only `[tag]` prefix — no filter, no pause, no clear
    - File: `app/lib/features/boot/boot_stage_panel.dart:322-478`, `service_providers.dart:211-220`
    - When something goes wrong, the operator scrolls a 500-line ringbuffer of mixed services. Auto-jump-to-bottom fights any attempt to scroll up. There's a Copy button but no Clear, no Pause, no per-service filter.
    - Expected: Filter chips, pause-on-hover, "Clear" alongside Copy.
    - Fix sketch: Add filter chips; suspend auto-scroll while user has scrolled away from bottom; Clear button.

20. **[NIT]** Verify panel implies first-boot tracking, but it isn't implemented
    - File: `app/lib/features/verify/verify_stage_panel.dart:78-86`
    - Verify table shows "flashed" or "PXE assigned" with no timestamp, no live first-boot status, no actionable guidance. Header copy implies the system tracks first-boot completion — it doesn't.
    - Expected: Display assignment timestamp, refresh button, link to Viam dashboard, adjust copy to admit the limitation.
    - Fix sketch: Add a column for assignment time; change subtitle to "Open Viam dashboard to confirm check-in"; add a `CupertinoButton` link to `app.viam.com`.

---

## Suggested order of work

1. **Real bugs** (Critic C #8, #12, #13, #17; A #4): sudo-cancellation handling,
   `dd` not killed on cancel, multi-disk detection, microcopy that lies, no
   `minSize`.
2. **Embarrassments** (A #1, #7, B #2, #3, #4, A #15): "APP_NAME" placeholder,
   `isDestructiveAction` on Cancel, hardcoded dark-mode greys, oversized toolbar,
   private font names.
3. **Workflow gating** (C #4, #11, #18, #6): disable stages until
   prerequisites met; gate Build Config behind Setup PXE; gate Start Services
   behind both; harden Clear.
4. **Discoverability** (C #1, #7, #16): empty-state CTA for first-launch;
   click-able service indicators with popover; real NIC selector.
5. **Type system + spacing pass** (B #1, #11, #12, #13, #16, #17): centralize
   theme, kill per-widget `fontSize:` literals, fix paddings.
6. **Hover / focus / keyboard** (A #5, #9, #14, #17, #18, B #18, C #14): wire
   shortcuts, hover states, focus rings, semantics.
7. **Structural migration** (A #2, #3, #6, #10, #11, #12, B #5, #20): adopt
   `macos_ui`, real menu bar bridge, real settings window, popovers.

Items 1 and 2 are weekend-able. 3 and 4 take a few days. 5–7 are larger
refactors that can land in stages.
