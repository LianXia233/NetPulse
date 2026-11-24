import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'theme.dart';

class PmCard extends StatelessWidget {
  const PmCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.gradient,
    this.color,
    this.radius = kCardRadius,
    this.border,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final Color? color;
  final double radius;
  final BorderSide? border;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final dark = context.isDark;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: border ??
          (dark
              ? BorderSide(color: Colors.white.withValues(alpha: 0.06))
              : BorderSide.none),
    );
    final content = Padding(padding: padding, child: child);
    final card = Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: ShapeDecoration(
        color: gradient == null ? (color ?? pm.card) : null,
        gradient: gradient,
        shape: shape,
        shadows: gradient != null
            ? [
                BoxShadow(
                  color: context.scheme.primary.withValues(alpha: dark ? 0.22 : 0.28),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ]
            : [
                if (!dark)
                  const BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 20,
                    offset: Offset(0, 7),
                  ),
                if (!dark)
                  const BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
              ],
      ),
      child: onTap == null ? content : PmPressable(onTap: onTap!, child: content),
    );
    return card;
  }
}

class PmPressable extends StatefulWidget {
  const PmPressable({super.key, required this.child, this.onTap, this.scale = 0.97});

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<PmPressable> createState() => _PmPressableState();
}

class _PmPressableState extends State<PmPressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapCancel: widget.onTap == null ? null : () => setState(() => _down = false),
      onTapUp: widget.onTap == null ? null : (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: kFast,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class PmSectionTitle extends StatelessWidget {
  const PmSectionTitle(this.title, {super.key, this.trailing, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: context.text.bodySmall?.copyWith(color: context.pm.muted),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class PmIconBadge extends StatelessWidget {
  const PmIconBadge(this.icon, {super.key, this.color, this.size = 42, this.radius = 13});

  final IconData icon;
  final Color? color;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.scheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: c.withValues(alpha: context.isDark ? 0.18 : 0.11),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      child: Icon(icon, size: size * 0.52, color: c),
    );
  }
}

class PmPill extends StatelessWidget {
  const PmPill({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.scheme.primary;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 12, vertical: dense ? 4 : 6),
      decoration: ShapeDecoration(
        color: c.withValues(alpha: context.isDark ? 0.16 : 0.10),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 12 : 14, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class PmStat extends StatelessWidget {
  const PmStat({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.tint,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: tint ?? pm.muted),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: pm.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: context.text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: tint,
                  ),
                ),
              ),
            ),
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(
                  unit!,
                  style: context.text.bodySmall?.copyWith(color: pm.muted, fontSize: 11),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 超椭圆量速表：环形渐变进度 + 呼吸光环 + 中心读数。
class PmGauge extends StatefulWidget {
  const PmGauge({
    super.key,
    required this.value,
    required this.maxValue,
    required this.headline,
    required this.unit,
    required this.caption,
    this.running = false,
    this.onTap,
    this.size = 268,
    this.buttonLabel,
  });

  final double value;
  final double maxValue;
  final String headline;
  final String unit;
  final String caption;
  final bool running;
  final VoidCallback? onTap;
  final double size;
  final String? buttonLabel;

  @override
  State<PmGauge> createState() => _PmGaugeState();
}

class _PmGaugeState extends State<PmGauge> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pm = context.pm;
    final progress = widget.maxValue <= 0
        ? 0.0
        : (widget.value / widget.maxValue).clamp(0.0, 1.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.running)
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _PulsePainter(_pulse.value, scheme.primary),
              ),
            ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            builder: (context, p, _) => CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _GaugePainter(
                progress: p,
                primary: scheme.primary,
                secondary: pm.series2,
                track: pm.track,
                dark: context.isDark,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.headline,
                style: context.text.displayMedium?.copyWith(
                  fontSize: widget.size * 0.175,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -2,
                  height: 1.05,
                ),
              ),
              Text(
                widget.unit,
                style: context.text.titleSmall?.copyWith(color: pm.muted, letterSpacing: 0.6),
              ),
              const SizedBox(height: 10),
              PmPressable(
                onTap: widget.onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      colors: widget.running
                          ? [pm.warn, pm.warn.withValues(alpha: 0.82)]
                          : [scheme.primary, Color.alphaBlend(Colors.white.withValues(alpha: 0.25), scheme.primary)],
                    ),
                    shape: const StadiumBorder(),
                    shadows: [
                      BoxShadow(
                        color: (widget.running ? pm.warn : scheme.primary).withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.buttonLabel ?? (widget.running ? '停止' : '开始测速'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.caption, style: context.text.bodySmall?.copyWith(color: pm.muted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final local = (t + i / 3) % 1;
      final radius = size.width * (0.32 + local * 0.18);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: (1 - local) * 0.22);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter old) => old.t != t;
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.progress,
    required this.primary,
    required this.secondary,
    required this.track,
    required this.dark,
  });

  final double progress;
  final Color primary;
  final Color secondary;
  final Color track;
  final bool dark;

  static const double startAngle = math.pi * 1.25; // 225°
  static const double totalSweep = math.pi * 1.5; // 270°

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 16;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = track.withValues(alpha: dark ? 0.55 : 0.7);
    canvas.drawArc(rect, startAngle, totalSweep, false, bg);

    // 刻度
    final tickPaint = Paint()
      ..strokeWidth = 1.2
      ..color = track.withValues(alpha: dark ? 0.7 : 0.9);
    for (var i = 0; i <= 36; i++) {
      final angle = startAngle + totalSweep * i / 36;
      final outer = Offset(center.dx + math.cos(angle) * (radius + 12), center.dy + math.sin(angle) * (radius + 12));
      final inner = Offset(center.dx + math.cos(angle) * (radius + 17), center.dy + math.sin(angle) * (radius + 17));
      canvas.drawLine(inner, outer, tickPaint);
    }

    if (progress <= 0) return;
    final sweep = totalSweep * progress;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..color = primary.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawArc(rect, startAngle, sweep, false, glow);

    final shader = SweepGradient(
      startAngle: startAngle,
      endAngle: startAngle + totalSweep,
      colors: [primary, secondary, primary],
      stops: const [0.0, 0.55, 1.0],
      transform: GradientRotation(startAngle),
    ).createShader(rect);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..shader = shader;
    canvas.drawArc(rect, startAngle, sweep, false, fg);

    final endAngle = startAngle + sweep;
    final dot = Offset(center.dx + math.cos(endAngle) * radius, center.dy + math.sin(endAngle) * radius);
    canvas.drawCircle(dot, 7, Paint()..color = Colors.white);
    canvas.drawCircle(dot, 4.5, Paint()..color = primary);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.progress != progress || old.primary != primary || old.dark != dark;
}

/// 实时曲线：渐变面积 + 平滑曲线 + 网格。
class PmChart extends StatelessWidget {
  const PmChart({
    super.key,
    required this.values,
    this.height = 132,
    this.maxValue,
    this.color,
    this.secondary,
    this.showGrid = true,
    this.filled = true,
  });

  final List<double> values;
  final double height;
  final double? maxValue;
  final Color? color;
  final List<double>? secondary;
  final bool showGrid;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.scheme.primary;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(
          values: values,
          secondary: secondary,
          maxValue: maxValue,
          color: c,
          muted: context.pm.muted,
          grid: context.pm.track,
          showGrid: showGrid,
          filled: filled,
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.values,
    required this.secondary,
    required this.maxValue,
    required this.color,
    required this.muted,
    required this.grid,
    required this.showGrid,
    required this.filled,
  });

  final List<double> values;
  final List<double>? secondary;
  final double? maxValue;
  final Color color;
  final Color muted;
  final Color grid;
  final bool showGrid;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (showGrid) {
      final gp = Paint()
        ..color = grid.withValues(alpha: 0.35)
        ..strokeWidth = 0.8;
      for (var i = 1; i < 4; i++) {
        final y = h * i / 4;
        canvas.drawLine(Offset(0, y), Offset(w, y), gp);
      }
    }
    if (values.length < 2) return;
    final maxV = maxValue ?? math.max(8.0, values.reduce(math.max) * 1.15);
    final n = values.length;
    double x(int i) => w * i / (n - 1);
    double y(double v) => h - (v / maxV).clamp(0.0, 1.0) * h;

    Path buildPath(List<double> data) {
      final path = Path()..moveTo(x(0), y(data[0]));
      for (var i = 0; i < data.length - 1; i++) {
        final x0 = x(i);
        final x1 = x(i + 1);
        final cx = (x0 + x1) / 2;
        path.cubicTo(cx, y(data[i]), cx, y(data[i + 1]), x1, y(data[i + 1]));
      }
      return path;
    }

    final path = buildPath(values);
    if (filled) {
      final fillPath = Path.from(path)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      final shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.26), color.withValues(alpha: 0.02)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
      canvas.drawPath(fillPath, Paint()..shader = shader);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(colors: [color.withValues(alpha: 0.72), color]).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    final sec = secondary;
    if (sec != null && sec.length >= 2) {
      final sp = buildPath(sec);
      canvas.drawPath(
        sp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..color = muted.withValues(alpha: 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.values != values || old.maxValue != maxValue || old.color != color;
}

class PmSegmented<T> extends StatelessWidget {
  const PmSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.height = 42,
  });

  final List<({T value, String label})> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final index = math.max(0, items.indexWhere((e) => e.value == value));
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: pm.block,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final itemW = box.maxWidth / items.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: kMid,
              curve: Curves.easeOutCubic,
              left: itemW * index,
              top: 0,
              bottom: 0,
              width: itemW,
              child: Container(
                decoration: ShapeDecoration(
                  color: pm.card,
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(11)),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: context.isDark ? 0.35 : 0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(item.value),
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: kFast,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: item.value == value ? FontWeight.w700 : FontWeight.w500,
                            color: item.value == value ? scheme.primary : pm.muted,
                          ),
                          child: Text(item.label),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

class PmSliderRow extends StatelessWidget {
  const PmSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.display,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String Function(double)? display;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: context.text.bodyMedium)),
            Text(
              display?.call(value) ?? value.toStringAsFixed(0),
              style: context.text.titleSmall?.copyWith(
                color: context.scheme.primary,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: context.scheme.primary,
            inactiveTrackColor: pm.track,
            thumbColor: Colors.white,
            overlayColor: context.scheme.primary.withValues(alpha: 0.12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions ?? (max - min).round(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class PmChip extends StatelessWidget {
  const PmChip({super.key, required this.label, this.onDelete, this.icon, this.color});

  final String label;
  final VoidCallback? onDelete;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: ShapeDecoration(
        color: pm.block,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color ?? context.scheme.primary),
            const SizedBox(width: 6),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(fontSize: 12),
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onDelete,
              child: Icon(Icons.close_rounded, size: 14, color: pm.muted),
            ),
          ],
        ],
      ),
    );
  }
}

Future<T?> showPmSheet<T>(
  BuildContext context, {
  required String title,
  required Widget body,
  bool scrollable = true,
  double maxHeight = 0.88,
  List<Widget> actions = const [],
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    useSafeArea: true,
    builder: (ctx) {
      final pm = ctx.pm;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: FractionallySizedBox(
          heightFactor: null,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * maxHeight),
            child: Container(
              decoration: ShapeDecoration(
                color: pm.page,
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(kSheetRadius)),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 38,
                    height: 5,
                    decoration: BoxDecoration(
                      color: pm.track,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: ctx.text.titleLarge?.copyWith(
                              fontSize: 19,
                              color: ctx.scheme.onSurface,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: Icon(Icons.close_rounded, color: pm.muted, size: 22),
                        ),
                      ],
                    ),
                  ),
                  if (scrollable)
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          18,
                          6,
                          18,
                          36 + MediaQuery.of(ctx).viewPadding.bottom,
                        ),
                        child: body,
                      ),
                    )
                  else
                    Flexible(child: body),
                  if (actions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      child: Row(children: actions),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class PmPrimaryButton extends StatelessWidget {
  const PmPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.expand = true,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;
  final bool expand;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pm = context.pm;
    final bg = destructive ? pm.warn : scheme.primary;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )
        else if (icon != null)
          Icon(icon, size: 18, color: Colors.white),
        if (icon != null || loading) const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ],
    );
    return PmPressable(
      onTap: onPressed,
      child: AnimatedOpacity(
        duration: kFast,
        opacity: onPressed == null ? 0.45 : 1,
        child: Container(
          height: 50,
          width: expand ? double.infinity : null,
          padding: expand ? null : const EdgeInsets.symmetric(horizontal: 22),
          decoration: ShapeDecoration(
            color: bg,
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
            shadows: [
              BoxShadow(color: bg.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 8)),
            ],
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class PmField extends StatelessWidget {
  const PmField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.suffix,
    this.obscure = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final bool obscure;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.text.bodySmall?.copyWith(fontSize: 13, color: context.scheme.onSurface.withValues(alpha: 0.72), fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: ShapeDecoration(
            color: pm.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: pm.inset),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  obscureText: obscure,
                maxLines: maxLines,
                  style: context.text.bodyMedium,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(
                      color: context.scheme.onSurface.withValues(alpha: 0.55),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
              if (suffix != null) suffix!,
            ],
          ),
        ),
      ],
    );
  }
}
