import 'package:flutter/cupertino.dart';

/// Monospace font stack used for logs, MAC addresses, device paths, etc.
/// Menlo ships with macOS; Monaco is the legacy fallback; Courier New is
/// the last-resort fallback elsewhere. We do not name the private ".SF Mono"
/// face since it's not a public font family.
const List<String> monospaceFontFallback = ['Menlo', 'Monaco', 'Courier New'];

CupertinoThemeData cupertinoTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: CupertinoColors.activeBlue,
    scaffoldBackgroundColor: isDark
        ? CupertinoColors.systemBackground.darkColor
        : CupertinoColors.systemBackground,
    barBackgroundColor: isDark
        ? CupertinoColors.secondarySystemBackground.darkColor
        : CupertinoColors.systemBackground.withOpacity(0.9),
    textTheme: CupertinoTextThemeData(
      textStyle: TextStyle(
        fontSize: 13,
        color: isDark ? CupertinoColors.white : CupertinoColors.black,
      ),
    ),
  );
}
