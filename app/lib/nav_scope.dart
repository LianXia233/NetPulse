import 'package:flutter/widgets.dart';

/// 供子页面切换底部标签。
class HomeNavScope extends InheritedWidget {
  const HomeNavScope({super.key, required this.go, required super.child});

  final void Function(int index) go;

  static void jump(BuildContext context, int index) {
    context.dependOnInheritedWidgetOfExactType<HomeNavScope>()?.go(index);
  }

  @override
  bool updateShouldNotify(HomeNavScope oldWidget) => false;
}
