import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse/plugin_runtime.dart';
import 'package:netpulse/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置站点解析器清单可加载且匹配规则正确', () async {
    final plugins = await SitePlugin.all();
    // 只约束「内置插件至少包含这些」，新增解析器不需要同步改这里。
    expect(plugins.length, greaterThanOrEqualTo(6));
    expect(
      plugins.map((p) => p.id),
      containsAll(<String>[
        'm3u8-pro',
        'github-accel',
        'quark-share',
        'accountdl',
        'musicdl',
        'bilibili',
        'anime-sites',
      ]),
    );

    // 清单不应出现重复 id
    expect(
      plugins.map((p) => p.id).toSet().length,
      plugins.length,
    );

    final m3u8 = plugins.firstWhere((p) => p.id == 'm3u8-pro');
    expect(
      m3u8.matches('https://cdn.example.com/live/index.m3u8?token=1'),
      isTrue,
    );
    expect(m3u8.matches('https://example.com/video.mp4'), isFalse);

    final gh = plugins.firstWhere((p) => p.id == 'github-accel');
    expect(
      gh.matches('https://github.com/a/b/releases/download/v1/x.zip'),
      isTrue,
    );
    expect(
      gh.matches('https://raw.githubusercontent.com/a/b/main/x.js'),
      isTrue,
    );
    expect(gh.matches('https://example.com/a.zip'), isFalse);

    final quark = plugins.firstWhere((p) => p.id == 'quark-share');
    expect(quark.matches('https://pan.quark.cn/s/abcdef'), isTrue);
    expect(quark.matches('https://pan.quark.cn/list'), isFalse);

    final bili = plugins.firstWhere((p) => p.id == 'bilibili');
    expect(bili.matches('https://www.bilibili.com/video/BV1xx411c7mD'), isTrue);
    expect(bili.matches('https://b23.tv/abc'), isTrue);
    expect(bili.matches('https://www.bilibili.com/'), isFalse);

    // 页面级解析器按站点匹配，不应落到任意资源直链上抢 m3u8-pro 的活。
    final anime = plugins.firstWhere((p) => p.id == 'anime-sites');
    expect(anime.matches('https://cdn.example.com/live/index.m3u8'), isFalse);
  });

  test('插件设置默认值与布尔/数字类型转换', () async {
    final plugins = await SitePlugin.all();
    final m3u8 = plugins.firstWhere((p) => p.id == 'm3u8-pro');
    final map = m3u8.settingsMap(_FakeStore());
    expect(map['maxHeight'], '1080');
    expect(map['injectHeaders'], true);
    expect(map['injectOrigin'], false);

    final quark = plugins.firstWhere((p) => p.id == 'quark-share');
    final qmap = quark.settingsMap(
      _FakeStore(
        settings: {
          'quark-share': {'maxFiles': '50'},
        },
      ),
    );
    expect(qmap['maxFiles'], 50);
  });
}

class _FakeStore extends AppStore {
  _FakeStore({this.settings = const {}});

  final Map<String, Map<String, String>> settings;

  @override
  Map<String, String> pluginSettingsOf(String id) => settings[id] ?? const {};
}
