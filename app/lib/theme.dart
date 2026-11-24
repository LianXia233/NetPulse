import 'package:flutter/material.dart';

/// 设计语言：iOS 蓝种子色、八色主题、超椭圆卡片、柔和层次。
const Color kSeedColor = Color(0xFF007AFF);
const List<Color> kAccentPalette = [
  Color(0xFF007AFF),
  Color(0xFFCB30E0),
  Color(0xFFFF2D55),
  Color(0xFFFF383C),
  Color(0xFFFF8D28),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF8E8E93),
];

const double kCardRadius = 20;
const double kSheetRadius = 28;
const double kPagePadding = 18;
const Duration kFast = Duration(milliseconds: 160);
const Duration kMid = Duration(milliseconds: 280);

class PmColors extends ThemeExtension<PmColors> {
  const PmColors({
    required this.page,
    required this.card,
    required this.block,
    required this.inset,
    required this.track,
    required this.series2,
    required this.muted,
    required this.ok,
    required this.warn,
    required this.okSoft,
    required this.warnSoft,
  });

  final Color page;
  final Color card;
  final Color block;
  final Color inset;
  final Color track;
  final Color series2;
  final Color muted;
  final Color ok;
  final Color warn;
  final Color okSoft;
  final Color warnSoft;

  static PmColors of(BuildContext context) =>
      Theme.of(context).extension<PmColors>() ??
      const PmColors(
        page: Color(0xFFF3F3F7),
        card: Colors.white,
        block: Color(0xFFEDEDF2),
        inset: Color(0xFFE3E3EA),
        track: Color(0xFFD9D9E2),
        series2: Color(0xFF66A9FF),
        muted: Color(0xFF6E6E7A),
        ok: Color(0xFF2FA84F),
        warn: Color(0xFFE05A2B),
        okSoft: Color(0xFFE4F5E9),
        warnSoft: Color(0xFFFCEAE3),
      );

  @override
  PmColors copyWith({
    Color? page,
    Color? card,
    Color? block,
    Color? inset,
    Color? track,
    Color? series2,
    Color? muted,
    Color? ok,
    Color? warn,
    Color? okSoft,
    Color? warnSoft,
  }) {
    return PmColors(
      page: page ?? this.page,
      card: card ?? this.card,
      block: block ?? this.block,
      inset: inset ?? this.inset,
      track: track ?? this.track,
      series2: series2 ?? this.series2,
      muted: muted ?? this.muted,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      okSoft: okSoft ?? this.okSoft,
      warnSoft: warnSoft ?? this.warnSoft,
    );
  }

  @override
  PmColors lerp(ThemeExtension<PmColors>? other, double t) {
    if (other is! PmColors) return this;
    return PmColors(
      page: Color.lerp(page, other.page, t)!,
      card: Color.lerp(card, other.card, t)!,
      block: Color.lerp(block, other.block, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      track: Color.lerp(track, other.track, t)!,
      series2: Color.lerp(series2, other.series2, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      okSoft: Color.lerp(okSoft, other.okSoft, t)!,
      warnSoft: Color.lerp(warnSoft, other.warnSoft, t)!,
    );
  }
}

/// FlClash 风格的页面转场：轻微上浮 + 淡入，避免 Android 默认的整页缩放。
class PmPageTransitionsBuilder extends PageTransitionsBuilder {
  const PmPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

ThemeData buildPmTheme({
  required Brightness brightness,
  required Color seed,
  required bool pureBlack,
}) {
  final isDark = brightness == Brightness.dark;
  // FlClash 的 vivid 方案保留种子色的高饱和主色，而不是 Material 默认压暗后的色值。
  final accent = isDark
      ? Color.alphaBlend(Colors.white.withValues(alpha: 0.22), seed)
      : seed;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(primary: accent, onPrimary: Colors.white);
  final page = isDark
      ? (pureBlack ? const Color(0xFF000000) : const Color(0xFF0B0B0E))
      : const Color(0xFFF2F3F5);
  final card = isDark
      ? (pureBlack ? const Color(0xFF080808) : const Color(0xFF16171B))
      : Colors.white;
  final block = isDark ? const Color(0xFF23242A) : const Color(0xFFE9EAEE);
  final inset = isDark ? const Color(0xFF2D2E35) : const Color(0xFFE1E2E7);
  final track = isDark ? const Color(0xFF383941) : const Color(0xFFD7D9DF);
  final muted = isDark ? const Color(0xFF9A9BA3) : const Color(0xFF6B6D76);
  final series2 = Color.alphaBlend(scheme.primary.withValues(alpha: 0.48), card);
  final colors = PmColors(
    page: page,
    card: card,
    block: block,
    inset: inset,
    track: track,
    series2: series2,
    muted: muted,
    ok: isDark ? const Color(0xFF4BD37B) : const Color(0xFF1F9D4D),
    warn: isDark ? const Color(0xFFFF8A5C) : const Color(0xFFD94E20),
    okSoft: isDark
        ? Color.alphaBlend(const Color(0xFF4BD37B).withValues(alpha: 0.16), card)
        : const Color(0xFFE2F6E9),
    warnSoft: isDark
        ? Color.alphaBlend(const Color(0xFFFF8A5C).withValues(alpha: 0.16), card)
        : const Color(0xFFFDEDE6),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme.copyWith(
      surface: page,
      onSurface: isDark ? const Color(0xFFEDEDF2) : const Color(0xFF15151A),
      surfaceContainerLowest: card,
      surfaceContainerLow: card,
      surfaceContainer: block,
      surfaceContainerHigh: block,
      surfaceContainerHighest: inset,
      outline: track,
      outlineVariant: inset,
    ),
    scaffoldBackgroundColor: page,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PmPageTransitionsBuilder(),
        TargetPlatform.iOS: PmPageTransitionsBuilder(),
      },
    ),
  );

  final text = base.textTheme;
  final tabular = [const FontFeature.tabularFigures()];
  return base.copyWith(
    extensions: [colors],
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -2.4,
        fontFeatures: tabular,
      ),
      displayMedium: text.displayMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.8,
        fontFeatures: tabular,
      ),
      headlineLarge: text.headlineLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.0,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      bodyMedium: text.bodyMedium?.copyWith(height: 1.35),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
    ),
    dividerTheme: DividerThemeData(color: inset, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      height: 66,
      elevation: 0,
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.12),
      indicatorShape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: selected ? scheme.primary : muted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? scheme.primary : muted,
        );
      }),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _PmPageTransitionsBuilder(),
        TargetPlatform.iOS: _PmPageTransitionsBuilder(),
      },
    ),
  );
}

class _PmPageTransitionsBuilder extends PageTransitionsBuilder {
  const _PmPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

extension PmContext on BuildContext {
  PmColors get pm => PmColors.of(this);
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

String formatMbps(double mbps) {
  if (mbps >= 1000) return (mbps / 1000).toStringAsFixed(2);
  if (mbps >= 100) return mbps.toStringAsFixed(1);
  if (mbps >= 10) return mbps.toStringAsFixed(2);
  return mbps.toStringAsFixed(3);
}

String unitOf(double mbps) => mbps >= 1000 ? 'Gbps' : 'Mbps';

String formatBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 1 : 2)} ${units[i]}';
}

String formatLatency(num ms) {
  if (ms <= 0) return '--';
  if (ms < 10) return ms.toStringAsFixed(2);
  return ms.toStringAsFixed(ms < 100 ? 1 : 0);
}
