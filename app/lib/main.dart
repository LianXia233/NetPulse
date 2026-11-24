import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';
import 'download_sheet.dart';
import 'floating_nav.dart';
import 'pages/dashboard.dart';
import 'pages/downloads_page.dart';
import 'pages/settings_page.dart';
import 'pages/speed_page.dart';
import 'pages/tools_page.dart';
import 'store.dart';
import 'theme.dart';
import 'nav_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NativeInfo.load();
  NativeInfo.listenPush();
  Core.i.init();
  final store = AppStore();
  await store.load();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(PmApp(store: store));
}

class PmApp extends StatelessWidget {
  const PmApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return AppScope(
          store: store,
          child: MaterialApp(
          title: 'NetPulse',
          debugShowCheckedModeBanner: false,
          themeMode: store.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 320),
          themeAnimationCurve: Curves.easeOutCubic,
          theme: buildPmTheme(
            brightness: Brightness.light,
            seed: store.seed,
            pureBlack: store.pureBlack,
          ),
          darkTheme: buildPmTheme(
            brightness: Brightness.dark,
            seed: store.seed,
            pureBlack: store.pureBlack,
          ),
          home: const HomeShell(),
        ),
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final PageController _controller = PageController();

  @override
  void initState() {
    super.initState();
    NativeInfo.pushedLink.addListener(_onPushedLink);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final link = await NativeInfo.takeInitialLink();
      if (!mounted || link == null || link.isEmpty) return;
      await showDownloadSheet(context, initialUrl: link);
    });
  }

  void _onPushedLink() {
    final link = NativeInfo.pushedLink.value;
    if (link == null || link.isEmpty || !mounted) return;
    NativeInfo.pushedLink.value = null;
    showDownloadSheet(context, initialUrl: link);
  }

  static const _navItems = [
    (item: NavDockItem(icon: Icons.grid_view_rounded, label: '仪表盘'), page: 0),
    (item: NavDockItem(icon: Icons.speed_rounded, label: '测速'), page: 1),
    (item: NavDockItem(icon: Icons.download_rounded, label: '下载'), page: 3),
    (item: NavDockItem(icon: Icons.handyman_rounded, label: '工具'), page: 2),
  ];

  @override
  void dispose() {
    NativeInfo.pushedLink.removeListener(_onPushedLink);
    _controller.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (index == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = index);
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.pm;
    return HomeNavScope(
      go: _go,
      child: Scaffold(
        backgroundColor: pm.page,
        body: PageView(
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _index = i),
          children: const [
            DashboardPage(),
            SpeedPage(),
            ToolsPage(),
            DownloadsPage(),
            SettingsPage(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(21, 0, 21, 8),
          child: FloatingNavDock(
            items: [for (final tab in _navItems) tab.item],
            selectedIndex: _navItems.indexWhere((tab) => tab.page == _index),
            onSelected: (i) => _go(_navItems[i].page),
          ),
        ),
      ),
    );
  }
}
