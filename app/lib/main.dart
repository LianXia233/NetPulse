import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';
import 'download_sheet.dart';
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

  static const _tabs = [
    (icon: Icons.dashboard_rounded, label: '概览'),
    (icon: Icons.speed_rounded, label: '测速'),
    (icon: Icons.tune_rounded, label: '工具'),
    (icon: Icons.download_rounded, label: '下载'),
    (icon: Icons.settings_rounded, label: '设置'),
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
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: pm.card,
            border: Border(
              top: BorderSide(color: pm.inset.withValues(alpha: 0.6)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _go,
              destinations: [
                for (final tab in _tabs)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.icon),
                    label: tab.label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
