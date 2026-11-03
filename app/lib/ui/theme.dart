import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Woi palette: deep-space navy, cyan (user / listening), violet-magenta
/// (assistant), amber (tools), mint (success). Text colours are tuned for
/// WCAG AA (>= 4.5:1) on every surface they are used on.
abstract final class WoiColors {
  static const bg0 = Color(0xFF03050B);
  static const bg1 = Color(0xFF0A1020);
  static const bg2 = Color(0xFF121A30);
  static const bg3 = Color(0xFF1A2440);
  static const cyan = Color(0xFF38E8FF);
  static const blue = Color(0xFF4D7CFF);
  static const violet = Color(0xFF9D8FFF);
  static const magenta = Color(0xFFFF4FD8);
  static const amber = Color(0xFFFFB547);
  static const mint = Color(0xFF3DFFB0);
  static const red = Color(0xFFFF5C7A);
  static const text = Color(0xFFE8F1FF);
  static const textDim = Color(0xFF9DAFCB);
  static const textFaint = Color(0xFF7A8CAB);
  static const glass = Color(0x0FFFFFFF);
  static const glassStrong = Color(0x1AFFFFFF);
  static const stroke = Color(0x1FFFFFFF);
  static const strokeStrong = Color(0x33FFFFFF);
}

/// Motion and shape tokens shared by every widget.
abstract final class WoiMotion {
  static const fast = Duration(milliseconds: 140);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0, 1.0);
}

abstract final class WoiRadii {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 26.0;
}

/// Minimum interactive size (Material / Apple HIG touch target).
const kTouchTarget = 48.0;

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

/// Small all-caps section label ("CONTEXT", "VOICE").
TextStyle eyebrow({Color color = WoiColors.textFaint, double size = 11}) =>
    body(size, weight: FontWeight.w700, color: color).copyWith(letterSpacing: 1.6);

/// Numbers that tick (token counts, timers) should not jitter.
const kTabular = [FontFeature.tabularFigures()];

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      waitDuration: const Duration(milliseconds: 400),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: display(20),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: WoiColors.bg1.withValues(alpha: 0.97),
      surfaceTintColor: Colors.transparent,
      scrimColor: Colors.black.withValues(alpha: 0.55),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(WoiRadii.xl)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: WoiColors.bg2,
      surfaceTintColor: Colors.transparent,
      textStyle: body(14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WoiRadii.md),
        side: const BorderSide(color: WoiColors.stroke),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(WoiColors.bg2),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WoiRadii.md),
            side: const BorderSide(color: WoiColors.stroke),
          ),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: WoiColors.textDim,
        hoverColor: WoiColors.cyan.withValues(alpha: 0.08),
        highlightColor: WoiColors.cyan.withValues(alpha: 0.12),
        minimumSize: const Size(40, 40),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: WoiColors.cyan),
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
