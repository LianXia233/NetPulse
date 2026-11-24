import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

class PmPageHeader extends StatelessWidget {
  const PmPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.showBack = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 10, kPagePadding, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBack)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _RoundIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.text.headlineLarge?.copyWith(
                    fontSize: 30,
                    height: 1.1,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      subtitle!,
                      style: context.text.bodySmall?.copyWith(color: pm.muted),
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: ShapeDecoration(
          color: pm.card,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(13)),
        ),
        child: Icon(icon, size: 18, color: pm.muted),
      ),
    );
  }
}

class PmIconAction extends StatelessWidget {
  const PmIconAction({super.key, required this.icon, this.onTap, this.badge});

  final IconData icon;
  final VoidCallback? onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        margin: const EdgeInsets.only(left: 8),
        decoration: ShapeDecoration(
          color: pm.card,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(13)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: context.scheme.primary),
            if (badge != null) ...[
              const SizedBox(width: 5),
              Text(
                badge!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.scheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void pmToast(BuildContext context, String message) {
  HapticFeedback.lightImpact();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: context.text.bodyMedium?.copyWith(
            color: context.scheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: context.pm.card,
        elevation: 8,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 96),
        duration: const Duration(seconds: 2),
      ),
    );
}

void confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  bool destructive = false,
  required VoidCallback onConfirm,
}) {
  showDialog(
    context: context,
    builder: (ctx) {
      final pm = ctx.pm;
      return AlertDialog(
        backgroundColor: pm.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(title, style: ctx.text.titleLarge?.copyWith(fontSize: 19, color: ctx.scheme.onSurface)),
        content: Text(
          message,
          style: ctx.text.bodyMedium?.copyWith(
            fontSize: 15,
            height: 1.45,
            color: ctx.scheme.onSurface.withValues(alpha: 0.82),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: pm.muted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: Text(
              confirmLabel,
              style: TextStyle(color: destructive ? pm.warn : ctx.scheme.primary),
            ),
          ),
        ],
      );
    },
  );
}
