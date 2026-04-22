import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// Monospace font stack used for logs, MAC addresses, device paths, etc.
/// Menlo ships with macOS; Monaco is the legacy fallback; Courier New is
/// the last-resort fallback elsewhere. We do not name the private ".SF Mono"
/// face since it's not a public font family.
const List<String> monospaceFontFallback = ['Menlo', 'Monaco', 'Courier New'];

MacosThemeData macosLightTheme() => MacosThemeData.light();

MacosThemeData macosDarkTheme() => MacosThemeData.dark();

/// PushButton styled with a red accent for destructive actions.
///
/// macos_ui 2.2.0's [PushButton.color] parameter does not paint the background
/// — it only influences the text contrast calculation, leaving the button
/// looking like a default accent button. Wrapping a PushButton in a MacosTheme
/// with `accentColor: AccentColor.red` produces the red gradient background.
class DestructivePushButton extends StatelessWidget {
  const DestructivePushButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.controlSize = ControlSize.large,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final ControlSize controlSize;

  @override
  Widget build(BuildContext context) {
    final base = MacosTheme.of(context);
    return MacosTheme(
      data: base.copyWith(accentColor: AccentColor.red),
      child: PushButton(
        controlSize: controlSize,
        onPressed: onPressed,
        child: child,
      ),
    );
  }
}
