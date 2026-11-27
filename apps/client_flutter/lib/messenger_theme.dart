import 'package:material_ui/material_ui.dart';

ThemeData messengerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff3390ec),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff83bfff) : const Color(0xff1265ab),
        onPrimary: dark ? const Color(0xff062c49) : Colors.white,
        surface: dark ? const Color(0xff161e27) : Colors.white,
        primaryContainer: dark
            ? const Color(0xff1d4660)
            : const Color(0xffdbedff),
        onPrimaryContainer: dark
            ? const Color(0xffe2f2ff)
            : const Color(0xff103451),
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
  );
}

class ChatTextScaler extends TextScaler {
  const ChatTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;
  @override
  double scale(double fontSize) => system.scale(fontSize * factor);
  @override
  double get textScaleFactor => scale(14) / 14;
  @override
  bool operator ==(Object other) =>
      other is ChatTextScaler &&
      system == other.system &&
      factor == other.factor;
  @override
  int get hashCode => Object.hash(system, factor);
}
