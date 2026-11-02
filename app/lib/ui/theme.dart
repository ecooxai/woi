import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Woi palette: deep space background, cyan (user / listening),
/// violet-magenta (assistant), amber (tools), mint (success).
abstract final class WoiColors {
  static const bg0 = Color(0xFF04060C);
  static const bg1 = Color(0xFF0A1020);
  static const bg2 = Color(0xFF121A30);
  static const cyan = Color(0xFF38E8FF);
  static const blue = Color(0xFF4D7CFF);
  static const violet = Color(0xFF8B7BFF);
  static const magenta = Color(0xFFFF4FD8);
  static const amber = Color(0xFFFFB547);
  static const mint = Color(0xFF3DFFB0);
  static const red = Color(0xFFFF5C7A);
  static const text = Color(0xFFE8F1FF);
  static const textDim = Color(0xFF93A6C4);
  static const textFaint = Color(0xFF5D6E8A);
  static const glass = Color(0x0FFFFFFF);
  static const glassStrong = Color(0x1AFFFFFF);
  static const stroke = Color(0x1FFFFFFF);
}

abstract final class WoiFonts {
  static const body = 'Inter';
  static const display = 'SpaceGrotesk';
  static const mono = 'JetBrainsMono';
}

/// Variable fonts need an explicit weight axis to render bold/light.
TextStyle weighted(TextStyle s, FontWeight w) =>
    s.copyWith(fontWeight: w, fontVariations: [FontVariation.weight(w.value.toDouble())]);

TextStyle display(double size, {FontWeight weight = FontWeight.w600, Color? color, double spacing = 0.4}) => weighted(
  TextStyle(fontFamily: WoiFonts.display, fontSize: size, color: color ?? WoiColors.text, letterSpacing: spacing),
  weight,
);

TextStyle body(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) => weighted(
  TextStyle(fontFamily: WoiFonts.body, fontSize: size, color: color ?? WoiColors.text, height: height),
  weight,
);

TextStyle mono(double size, {Color? color, double? height}) =>
    TextStyle(fontFamily: WoiFonts.mono, fontSize: size, color: color ?? WoiColors.text, height: height ?? 1.45);

ThemeData buildWoiTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: WoiColors.cyan, brightness: Brightness.dark).copyWith(
    primary: WoiColors.cyan,
    onPrimary: WoiColors.bg0,
    secondary: WoiColors.violet,
    tertiary: WoiColors.magenta,
    error: WoiColors.red,
    surface: WoiColors.bg1,
    onSurface: WoiColors.text,
    surfaceContainerHighest: WoiColors.bg2,
    outline: WoiColors.stroke,
  );

  TextStyle t(double size, FontWeight w, [Color c = WoiColors.text]) => body(size, weight: w, color: c);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: WoiColors.bg0,
    fontFamily: WoiFonts.body,
    textTheme: TextTheme(
      displayLarge: display(44, weight: FontWeight.w600),
      headlineMedium: display(26),
      headlineSmall: display(22),
      titleLarge: display(19),
      titleMedium: t(15, FontWeight.w600),
      titleSmall: t(13, FontWeight.w600, WoiColors.textDim),
      bodyLarge: t(15, FontWeight.w400),
      bodyMedium: t(14, FontWeight.w400),
      bodySmall: t(12, FontWeight.w400, WoiColors.textDim),
      labelLarge: t(14, FontWeight.w600),
      labelMedium: t(12, FontWeight.w500, WoiColors.textDim),
      labelSmall: t(11, FontWeight.w500, WoiColors.textDim),
    ),
    dividerTheme: const DividerThemeData(color: WoiColors.stroke, thickness: 1, space: 1),
    iconTheme: const IconThemeData(color: WoiColors.textDim),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: WoiColors.bg2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WoiColors.stroke),
      ),
      textStyle: body(12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: WoiColors.bg1.withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: WoiColors.stroke),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WoiColors.glass,
      hintStyle: body(14, color: WoiColors.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: WoiColors.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: WoiColors.stroke),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: WoiColors.cyan.withValues(alpha: 0.7)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WoiColors.cyan,
        foregroundColor: WoiColors.bg0,
        textStyle: body(14, weight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WoiColors.text,
        side: const BorderSide(color: WoiColors.stroke),
        textStyle: body(14, weight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: WoiColors.cyan,
        textStyle: body(14, weight: FontWeight.w600),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? WoiColors.bg0 : WoiColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? WoiColors.cyan : WoiColors.glassStrong,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: WoiColors.cyan,
      inactiveTrackColor: WoiColors.glassStrong,
      thumbColor: WoiColors.cyan,
      overlayColor: WoiColors.cyan.withValues(alpha: 0.12),
      valueIndicatorColor: WoiColors.bg2,
      valueIndicatorTextStyle: body(12),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.all(const BorderSide(color: WoiColors.stroke)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? WoiColors.cyan.withValues(alpha: 0.16) : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? WoiColors.cyan : WoiColors.textDim,
        ),
        textStyle: WidgetStateProperty.all(body(13, weight: FontWeight.w600)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: WoiColors.bg2,
      contentTextStyle: body(14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(WoiColors.textFaint.withValues(alpha: 0.4)),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(6),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
