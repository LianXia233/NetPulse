import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class NavDockItem {
  const NavDockItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// FlClash 风格的悬浮胶囊导航：底部留白、白色浮层、选中项灰色 lens，
/// 支持点击、横向拖动跟手和回弹动画。
class FloatingNavDock extends StatefulWidget {
  const FloatingNavDock({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<NavDockItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<FloatingNavDock> createState() => _FloatingNavDockState();
}

class _FloatingNavDockState extends State<FloatingNavDock>
    with SingleTickerProviderStateMixin {
  static const double _height = 62;
  static const double _padding = 4;
  static const double _iconSize = 27;

  late final AnimationController _travel = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..addListener(_onTravel);

  double _lens = 0;
  double _from = 0;
  double _to = 0;
  double _stretch = 0;
  bool _pressed = false;
  bool _dragging = false;
  int _preview = 0;

  @override
  void initState() {
    super.initState();
    _lens = math.max(widget.selectedIndex, 0).toDouble();
    _preview = widget.selectedIndex;
  }

  @override
  void didUpdateWidget(covariant FloatingNavDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.selectedIndex != widget.selectedIndex) {
      _preview = widget.selectedIndex;
      if (widget.selectedIndex >= 0) {
        _animateTo(widget.selectedIndex.toDouble());
      } else {
        setState(() {});
      }
    }
  }

  void _onTravel() {
    setState(() {
      final t = Curves.easeOutCubic.transform(_travel.value);
      _lens = lerpDouble(_from, _to, t) ?? _to;
    });
  }

  void _animateTo(double target) {
    _from = _lens;
    _to = target;
    _travel.forward(from: 0);
  }

  ({double pitch, double lens, double inset}) _layout(double span) {
    final count = math.max(widget.items.length, 1);
    final crowded = span / count < 68;
    final inset = crowded ? 10.0 : _padding;
    final pitch = (span - inset * 2) / count;
    return (pitch: pitch, lens: pitch + inset * 2, inset: inset);
  }

  void _select(int index, {bool haptic = true}) {
    final clamped = index.clamp(0, widget.items.length - 1);
    if (haptic && clamped != widget.selectedIndex) {
      HapticFeedback.selectionClick();
    }
    _preview = clamped;
    _animateTo(clamped.toDouble());
    if (clamped != widget.selectedIndex) widget.onSelected(clamped);
  }

  void _onDown(Offset localPosition, double width) {
    _travel.stop();
    _pressed = true;
    _dragging = true;
    _updateDrag(localPosition.dx, width, 0);
  }

  void _onUpdate(DragUpdateDetails d, double width) {
    _updateDrag(d.localPosition.dx, width, d.delta.dx);
  }

  void _updateDrag(double dx, double width, double deltaX) {
    final layout = _layout(width);
    final unit = ((dx - _padding - layout.inset) / layout.pitch - 0.5)
        .clamp(0.0, (widget.items.length - 1).toDouble());
    final nextPreview = unit.round().clamp(0, widget.items.length - 1);
    setState(() {
      _lens = unit;
      _stretch = (deltaX * 0.0015).clamp(-0.035, 0.035);
      if (nextPreview != _preview) {
        _preview = nextPreview;
        HapticFeedback.selectionClick();
      }
    });
  }

  void _onEnd() {
    setState(() {
      _pressed = false;
      _dragging = false;
      _stretch = 0;
    });
    _select(_preview, haptic: false);
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    final scheme = context.scheme;
    final dark = context.isDark;
    final lensColor = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), pm.card)
        : Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.055), pm.card);
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: Container(
        height: _height,
        decoration: ShapeDecoration(
          color: pm.card.withValues(alpha: dark ? 0.94 : 0.98),
          shape: StadiumBorder(
            side: BorderSide(color: pm.inset.withValues(alpha: 0.55)),
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.42 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.20 : 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - _padding * 2;
            final layout = _layout(width);
            final lensWidth = layout.lens * (1 + _stretch);
            final lensHeight = (_height - _padding * 2) * (1 - _stretch * 1.4);
            final lensLeft =
                _padding + (_lens + 0.5) * layout.pitch + layout.inset - lensWidth / 2;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onDown(d.localPosition, width),
              onTapUp: (_) => _onEnd(),
              onTapCancel: _onEnd,
              onHorizontalDragStart: (d) => _onDown(d.localPosition, width),
              onHorizontalDragUpdate: (d) => _onUpdate(d, width),
              onHorizontalDragEnd: (_) => _onEnd(),
              onHorizontalDragCancel: _onEnd,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedPositioned(
                    duration: _dragging
                        ? Duration.zero
                        : const Duration(milliseconds: 40),
                    curve: Curves.easeOut,
                    left: lensLeft,
                    top: (_height - lensHeight) / 2,
                    width: lensWidth,
                    height: lensHeight,
                    child: AnimatedOpacity(
                      opacity: _preview >= 0 ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: lensColor,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(_padding),
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          Expanded(
                            child: _DockItem(
                              item: widget.items[i],
                              selected: i == _preview && _preview >= 0,
                              iconSize: _iconSize,
                              onTap: () => _select(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.item,
    required this.selected,
    required this.iconSize,
    required this.onTap,
  });

  final NavDockItem item;
  final bool selected;
  final double iconSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pm = context.pm;
    final color = selected
        ? scheme.primary
        : (context.isDark
            ? pm.muted.withValues(alpha: 0.92)
            : scheme.onSurface.withValues(alpha: 0.66));
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: selected ? 1.08 : 1,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutBack,
              child: Icon(item.icon, size: iconSize, color: color),
            ),
            const SizedBox(height: 1),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.2,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.1,
                color: color,
              ),
              child: Text(
                item.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
