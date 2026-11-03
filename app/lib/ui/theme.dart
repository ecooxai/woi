import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../core/settings/settings.dart';

/// One colour set. The semantic names stay the same in both themes:
/// [cyan] is the primary accent (user / listening / actions), [violet] the
/// assistant, [magenta] speech, [amber] tools, [mint] success, [red] errors.
/// Text colours meet WCAG AA (>= 4.5:1) on [bg0] and [bg1].
class WoiPalette {
  const WoiPalette({
    required this.brightness,
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.cyan,
    required this.blue,
    required this.violet,
    required this.magenta,
    required this.amber,
    required this.mint,
    required this.red,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.glass,
    required this.glassStrong,
    required this.stroke,
    required this.strokeStrong,
    required this.onAccent,
    required this.shadow,
  });

  final Brightness brightness;

  /// Window background.
  final Color bg0;

  /// Cards and panels.
  final Color bg1;

  /// Raised fills: menus, tooltips, hover.
  final Color bg2;
  final Color bg3;
  final Color cyan;
  final Color blue;
  final Color violet;
  final Color magenta;
  final Color amber;
  final Color mint;
  final Color red;
  final Color text;
  final Color textDim;
  final Color textFaint;

  /// Subtle neutral fills (wells, inactive tracks).
  final Color glass;
  final Color glassStrong;

  /// Hairline borders.
  final Color stroke;
  final Color strokeStrong;

  /// Text/icons on an accent fill.
  final Color onAccent;

  /// Shadow colour for the few elevated surfaces.
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  static const light = WoiPalette(
    brightness: Brightness.light,
    bg0: Color(0xFFF6F7F9),
    bg1: Color(0xFFFFFFFF),
    bg2: Color(0xFFF1F3F6),
    bg3: Color(0xFFE6E9EE),
    cyan: Color(0xFF2563EB),
    blue: Color(0xFF1D4ED8),
    violet: Color(0xFF7C3AED),
    magenta: Color(0xFFC026D3),
    amber: Color(0xFFB45309),
    mint: Color(0xFF047857),
    red: Color(0xFFDC2626),
    text: Color(0xFF15171C),
    textDim: Color(0xFF545B67),
    textFaint: Color(0xFF6B7280),
    glass: Color(0x0A0F172A),
    glassStrong: Color(0x140F172A),
    stroke: Color(0x1A0F172A),
    strokeStrong: Color(0x330F172A),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x140F172A),
  );

  static const dark = WoiPalette(
    brightness: Brightness.dark,
    bg0: Color(0xFF0F1115),
    bg1: Color(0xFF16191F),
    bg2: Color(0xFF1E2229),
    bg3: Color(0xFF272C34),
    cyan: Color(0xFF6EA8FE),
    blue: Color(0xFF4D8DF7),
    violet: Color(0xFFA78BFA),
    magenta: Color(0xFFF472B6),
    amber: Color(0xFFFBBF24),
    mint: Color(0xFF34D399),
    red: Color(0xFFF87171),
    text: Color(0xFFE8EAED),
    textDim: Color(0xFFA3A9B4),
    textFaint: Color(0xFF8A919C),
    glass: Color(0x0AFFFFFF),
    glassStrong: Color(0x14FFFFFF),
    stroke: Color(0x1AFFFFFF),
    strokeStrong: Color(0x33FFFFFF),
    onAccent: Color(0xFF0F1115),
    shadow: Color(0x66000000),
  );
}

/// The palette for a theme setting ([platform] resolves "system").
WoiPalette paletteFor(AppTheme t, Brightness platform) => switch (t) {
  AppTheme.light => WoiPalette.light,
  AppTheme.dark => WoiPalette.dark,
  AppTheme.system => platform == Brightness.dark ? WoiPalette.dark : WoiPalette.light,
};

/// Colours of the active palette. Widgets read them while building, so a
/// theme switch re-builds the whole tree (see [WoiColors.use]).
abstract final class WoiColors {
  static WoiPalette _p = WoiPalette.light;
  static WoiPalette get palette => _p;

  /// Switches the palette; returns whether it changed.
  static bool use(WoiPalette p) {
    if (identical(p, _p)) return false;
    _p = p;
    return true;
  }

  static Color get bg0 => _p.bg0;
  static Color get bg1 => _p.bg1;
  static Color get bg2 => _p.bg2;
  static Color get bg3 => _p.bg3;
  static Color get cyan => _p.cyan;
  static Color get blue => _p.blue;
  static Color get violet => _p.violet;
  static Color get magenta => _p.magenta;
  static Color get amber => _p.amber;
  static Color get mint => _p.mint;
  static Color get red => _p.red;
  static Color get text => _p.text;
  static Color get textDim => _p.textDim;
  static Color get textFaint => _p.textFaint;
  static Color get glass => _p.glass;
  static Color get glassStrong => _p.glassStrong;
  static Color get stroke => _p.stroke;
  static Color get strokeStrong => _p.strokeStrong;
  static Color get onAccent => _p.onAccent;
  static Color get shadow => _p.shadow;
}

/// Motion and shape tokens shared by every widget.
abstract final class WoiMotion {
  static const fast = Duration(milliseconds: 120);
  static const medium = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0, 1.0);
}

abstract final class WoiRadii {
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const xl = 18.0;
}

/// Minimum interactive size (Material / Apple HIG touch target).
const kTouchTarget = 48.0;

abstract final class WoiFonts {
  static const body = 'Inter';
  static const display = 'Inter';
  static const mono = 'JetBrainsMono';
}

/// Variable fonts need an explicit weight axis to render bold/light.
TextStyle weighted(TextStyle s, FontWeight w) =>
    s.copyWith(fontWeight: w, fontVariations: [FontVariation.weight(w.value.toDouble())]);

/// Headings: Inter, semibold, slightly tight.
TextStyle display(double size, {FontWeight weight = FontWeight.w600, Color? color, double spacing = -0.2}) => weighted(
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
TextStyle eyebrow({Color? color, double size = 11}) =>
    body(size, weight: FontWeight.w600, color: color ?? WoiColors.textFaint).copyWith(letterSpacing: 0.8);

/// Numbers that tick (token counts, timers) should not jitter.
const kTabular = [FontFeature.tabularFigures()];

/// Hairline-bordered surface decoration used by panels and bars.
BoxDecoration surfaceDecoration({double radius = WoiRadii.lg, Color? color, bool elevated = false}) => BoxDecoration(
  color: color ?? WoiColors.bg1,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: WoiColors.stroke),
  boxShadow: elevated
      ? [BoxShadow(color: WoiColors.shadow, blurRadius: 16, offset: const Offset(0, 4))]
      : [BoxShadow(color: WoiColors.shadow.withValues(alpha: WoiColors.palette.isDark ? 0.2 : 0.5), blurRadius: 2, offset: const Offset(0, 1))],
);

ThemeData buildWoiTheme([WoiPalette? palette]) {
  final p = palette ?? WoiColors.palette;
  final scheme = ColorScheme.fromSeed(seedColor: p.cyan, brightness: p.brightness).copyWith(
    primary: p.cyan,
    onPrimary: p.onAccent,
    secondary: p.violet,
    tertiary: p.magenta,
    error: p.red,
    surface: p.bg1,
    onSurface: p.text,
    onSurfaceVariant: p.textDim,
    surfaceContainerHighest: p.bg2,
    surfaceContainerHigh: p.bg2,
    surfaceContainer: p.bg1,
    surfaceContainerLow: p.bg1,
    outline: p.strokeStrong,
    outlineVariant: p.stroke,
  );

  TextStyle t(double size, FontWeight w, [Color? c]) => body(size, weight: w, color: c ?? p.text);

  final menuShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(WoiRadii.md),
    side: BorderSide(color: p.stroke),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg0,
    canvasColor: p.bg1,
    fontFamily: WoiFonts.body,
    // InkSparkle uses a shader; the plain ripple is cheaper on software GL.
    splashFactory: InkRipple.splashFactory,
    textTheme: TextTheme(
      displayLarge: display(40),
      headlineMedium: display(24),
      headlineSmall: display(20),
      titleLarge: display(18),
      titleMedium: t(15, FontWeight.w600),
      titleSmall: t(13, FontWeight.w600, p.textDim),
      bodyLarge: t(15, FontWeight.w400),
      bodyMedium: t(14, FontWeight.w400),
      bodySmall: t(12, FontWeight.w400, p.textDim),
      labelLarge: t(14, FontWeight.w500),
      labelMedium: t(12, FontWeight.w500, p.textDim),
      labelSmall: t(11, FontWeight.w500, p.textDim),
    ),
    dividerTheme: DividerThemeData(color: p.stroke, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.textDim),
    // Surface-coloured so rich tooltips (context breakdown) use normal text colours.
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.isDark ? p.bg3 : p.bg1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.stroke),
        boxShadow: [BoxShadow(color: p.shadow, blurRadius: 12, offset: const Offset(0, 3))],
      ),
      textStyle: body(12, color: p.text),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg0,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: display(18),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.bg1,
      surfaceTintColor: Colors.transparent,
      scrimColor: Colors.black.withValues(alpha: p.isDark ? 0.5 : 0.25),
      shape: const RoundedRectangleBorder(),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.bg1,
      surfaceTintColor: Colors.transparent,
      textStyle: body(14),
      elevation: 3,
      shadowColor: p.shadow,
      shape: menuShape,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(p.bg1),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shadowColor: WidgetStateProperty.all(p.shadow),
        shape: WidgetStateProperty.all(menuShape),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.textDim,
        hoverColor: p.glass,
        highlightColor: p.glassStrong,
        minimumSize: const Size(40, 40),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.cyan),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg1,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: p.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WoiRadii.xl),
        side: BorderSide(color: p.stroke),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg1,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: p.strokeStrong,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.bg1,
      hintStyle: body(14, color: p.textFaint),
      labelStyle: body(14, color: p.textDim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoiRadii.md),
        borderSide: BorderSide(color: p.strokeStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoiRadii.md),
        borderSide: BorderSide(color: p.strokeStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoiRadii.md),
        borderSide: BorderSide(color: p.cyan, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.cyan,
        foregroundColor: p.onAccent,
        textStyle: body(14, weight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoiRadii.md)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.strokeStrong),
        textStyle: body(14, weight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoiRadii.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.cyan,
        textStyle: body(14, weight: FontWeight.w600),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.cyan : p.textFaint),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.textFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.cyan : p.glassStrong),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : p.strokeStrong,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.cyan,
      inactiveTrackColor: p.glassStrong,
      thumbColor: p.cyan,
      overlayColor: p.cyan.withValues(alpha: 0.12),
      valueIndicatorColor: p.isDark ? p.bg3 : const Color(0xFF1F2329),
      valueIndicatorTextStyle: body(12, color: Colors.white),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.all(BorderSide(color: p.stroke)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.cyan.withValues(alpha: 0.12) : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.cyan : p.textDim,
        ),
        textStyle: WidgetStateProperty.all(body(13, weight: FontWeight.w600)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.isDark ? p.bg3 : const Color(0xFF1F2329),
      contentTextStyle: body(14, color: p.isDark ? p.text : Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoiRadii.md)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(p.textFaint.withValues(alpha: 0.35)),
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
