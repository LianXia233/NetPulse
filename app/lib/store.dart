import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'theme.dart';

class HistoryRecord {
  HistoryRecord({
    required this.id,
    required this.kind,
    required this.time,
    required this.title,
    required this.value,
    required this.unit,
    required this.detail,
  });

  final String id;
  final String kind;
  final DateTime time;
  final String title;
  final String value;
  final String unit;
  final Map<String, dynamic> detail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'time': time.toIso8601String(),
    'title': title,
    'value': value,
    'unit': unit,
    'detail': detail,
  };

  static HistoryRecord fromJson(Map<String, dynamic> j) => HistoryRecord(
    id: j['id']?.toString() ?? '',
    kind: j['kind']?.toString() ?? 'speed',
    time: DateTime.tryParse(j['time']?.toString() ?? '') ?? DateTime.now(),
    title: j['title']?.toString() ?? '',
    value: j['value']?.toString() ?? '',
    unit: j['unit']?.toString() ?? '',
    detail: (j['detail'] as Map?)?.cast<String, dynamic>() ?? {},
  );
}

const String kDefaultDownloadDir = '/storage/emulated/0/Download/NetPulse';
const String kAppVersion = '1.5.0';

String _dnsKey(String value) {
  var key = value.trim().toLowerCase();
  if (key.startsWith('tls://')) key = 'dot://${key.substring(6)}';
  if (key.startsWith('dot://')) {
    key = key.replaceFirst(RegExp(r'/+$'), '');
    if (key.endsWith(':853')) key = key.substring(0, key.length - 4);
  } else if (key.startsWith('https://')) {
    key = key.replaceFirst(RegExp(r'/+$'), '');
  } else if (key.endsWith(':53')) {
    key = key.substring(0, key.length - 3);
  }
  return key;
}

List<String> normalizeDnsList(Iterable<String> values) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty || value.startsWith('#')) continue;
    if (seen.add(_dnsKey(value))) out.add(value);
  }
  return out;
}

class AppStore extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  Color seed = kSeedColor;
  bool pureBlack = false;
  bool useMbps = true;
  int pingCount = 20;
  int workers = 8;
  int durationSec = 15;
  int sampleMs = 1000;
  List<String> endpoints = const [
    'https://speed.cloudflare.com/__down?bytes=50000000',
    'https://speed.hetzner.de/100MB.bin',
    'https://proof.ovh.net/files/100Mb.dat',
    'https://speedtest.tele2.net/100MB.zip',
    'https://download.thinkbroadband.com/100MB.zip',
    'https://mirror.leaseweb.com/speedtest/100mb.bin',
    'https://cachefly.cachefly.net/100mb.test',
  ];
  List<String> dnsServers = const [
    '223.5.5.5',
    '119.29.29.29',
    'https://dns.alidns.com/dns-query',
    'https://doh.pub/dns-query',
    '8.8.8.8',
    '1.1.1.1',
    'dot://dns.alidns.com',
    'dot://dot.pub',
  ];
  List<String> uploadEndpoints = const [
    'https://speed.cloudflare.com/__up',
    'https://httpbin.org/post',
    'https://httpbun.com/post',
    'https://echo.zuplo.io/',
  ];
  String uploadEndpoint = 'https://speed.cloudflare.com/__up';
  int downloadConnections = 8;
  int downloadBlockKb = 1024;
  int downloadRetries = 2;
  List<String> downloadMirrors = [];
  List<String> downloadDns = [
    '223.5.5.5',
    '119.29.29.29',
    'https://dns.alidns.com/dns-query',
    'https://doh.pub/dns-query',
    '8.8.8.8',
  ];
  String downloadUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';
  String downloadDir = kDefaultDownloadDir;
  String downloadBind = '';
  String speedBind = '';
  String downloadIpMode = 'auto';
  String speedIpMode = 'auto';
  String downloadDnsMode = 'all';
  String speedDnsMode = 'all';
  String ipdbUrl = '';
  String ipApiEndpoint = 'https://ipwho.is/{ip}';
  static const ipApiPresets = [
    ('ipwho.is', 'https://ipwho.is/{ip}'),
    ('ipapi.is', 'https://api.ipapi.is/?q={ip}'),
    ('IP.SB', 'https://api.ip.sb/geoip/{ip}'),
    ('proxycheck.io', 'https://proxycheck.io/v2/{ip}?vpn=1&asn=1&risk=1'),
    ('ip-api.com', 'http://ip-api.com/json/{ip}'),
    ('ipapi.co', 'https://ipapi.co/{ip}/json/'),
    ('ipinfo.io', 'https://ipinfo.io/{ip}/json'),
  ];
  // 内置浏览器
  String browserHome = '';
  String browserUaMode = 'system'; // system / desktop / custom
  String browserUaCustom = '';
  bool browserJavaScript = true;
  bool browserSniff = true;
  bool browserIntercept = true;
  /// 用户脚本（GreasyFork 等）总开关。
  bool userScriptsEnabled = true;
  String get downloadDirEffective =>
      downloadDir.trim().isEmpty ? kDefaultDownloadDir : downloadDir.trim();
  List<HistoryRecord> history = [];

  /// 下载任务记录：进程被杀后仍能在下载页恢复并继续断点续传。
  List<Map<String, dynamic>> downloadRecords = [];

  /// 站点解析器（FluxDown 兼容插件）的用户设置，按插件 id 分组。
  Map<String, Map<String, String>> pluginSettings = {};

  /// 插件自己的持久化键值（登录态缓存、加速源选择等）。
  Map<String, String> pluginStorage = {};

  String _path = '';

  String get uploadCandidates =>
      uploadEndpoints.isEmpty ? uploadEndpoint : uploadEndpoints.join('\n');

  List<String> get speedEndpoints => endpoints;

  Future<void> load() async {
    _path = '${NativeInfo.filesDir}/netpulse_state.json';
    try {
      final file = File(_path);
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        themeMode = ThemeMode.values[(j['themeMode'] as int? ?? 0).clamp(0, 2)];
        seed = Color(j['seed'] as int? ?? kSeedColor.toARGB32());
        pureBlack = j['pureBlack'] == true;
        useMbps = j['useMbps'] != false;
        pingCount = (j['pingCount'] as int? ?? 20).clamp(1, 500);
        workers = (j['workers'] as int? ?? 8).clamp(1, 64);
        durationSec = (j['durationSec'] as int? ?? 15).clamp(3, 120);
        sampleMs = (j['sampleMs'] as int? ?? 1000).clamp(100, 2000);
        if (j['endpoints'] is List) {
          endpoints = (j['endpoints'] as List)
              .map((e) => e.toString())
              .toList();
        }
        if (j['dnsServers'] is List) {
          dnsServers = normalizeDnsList(
            (j['dnsServers'] as List).map((e) => e.toString()),
          );
        }
        uploadEndpoint = j['uploadEndpoint']?.toString() ?? uploadEndpoint;
        if (j['uploadEndpoints'] is List) {
          uploadEndpoints = (j['uploadEndpoints'] as List)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        } else if (uploadEndpoint.isNotEmpty) {
          uploadEndpoints = [uploadEndpoint];
        }
        if (uploadEndpoints.isNotEmpty) uploadEndpoint = uploadEndpoints.first;
        downloadConnections = (j['downloadConnections'] as int? ?? 8).clamp(
          1,
          32,
        );
        downloadBlockKb = (j['downloadBlockKb'] as int? ?? 1024).clamp(
          64,
          8192,
        );
        downloadRetries = (j['downloadRetries'] as int? ?? 2).clamp(0, 10);
        if (j['downloadMirrors'] is List) {
          downloadMirrors = (j['downloadMirrors'] as List)
              .map((e) => e.toString())
              .toList();
        }
        if (j['downloadDns'] is List) {
          downloadDns = normalizeDnsList(
            (j['downloadDns'] as List).map((e) => e.toString()),
          );
        }
        downloadUserAgent =
            j['downloadUserAgent']?.toString() ?? downloadUserAgent;
        downloadDir = j['downloadDir']?.toString() ?? downloadDir;
        if (downloadDir.trim().isEmpty) downloadDir = kDefaultDownloadDir;
        downloadBind = j['downloadBind']?.toString() ?? downloadBind;
        speedBind = j['speedBind']?.toString() ?? speedBind;
        downloadIpMode = j['downloadIpMode']?.toString() ?? downloadIpMode;
        speedIpMode = j['speedIpMode']?.toString() ?? speedIpMode;
        downloadDnsMode = j['downloadDnsMode']?.toString() ?? downloadDnsMode;
        speedDnsMode = j['speedDnsMode']?.toString() ?? speedDnsMode;
        ipdbUrl = j['ipdbUrl']?.toString() ?? ipdbUrl;
        ipApiEndpoint = j['ipApiEndpoint']?.toString() ?? ipApiEndpoint;
        browserHome = j['browserHome']?.toString() ?? browserHome;
        browserUaMode = j['browserUaMode']?.toString() ?? browserUaMode;
        browserUaCustom = j['browserUaCustom']?.toString() ?? browserUaCustom;
        browserJavaScript = j['browserJavaScript'] != false;
        browserSniff = j['browserSniff'] != false;
        browserIntercept = j['browserIntercept'] != false;
        userScriptsEnabled = j['userScriptsEnabled'] != false;
        // 旧版本默认使用明文 ip-api，升级后迁移到 HTTPS 源。
        if (ipApiEndpoint.contains('ip-api.com')) {
          ipApiEndpoint = 'https://ipwho.is/{ip}';
        }
        if (j['history'] is List) {
          history = (j['history'] as List)
              .whereType<Map>()
              .map((e) => HistoryRecord.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
        if (j['downloadRecords'] is List) {
          downloadRecords = (j['downloadRecords'] as List)
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .where((e) => (e['url']?.toString() ?? '').isNotEmpty)
              .toList();
        }
        if (j['pluginSettings'] is Map) {
          final raw = j['pluginSettings'] as Map;
          pluginSettings = {
            for (final e in raw.entries)
              if (e.value is Map)
                e.key.toString(): (e.value as Map).map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                ),
          };
        }
        if (j['pluginStorage'] is Map) {
          pluginStorage = (j['pluginStorage'] as Map).map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
          );
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> save() async {
    if (_path.isEmpty) return;
    final j = {
      'themeMode': themeMode.index,
      'seed': seed.toARGB32(),
      'pureBlack': pureBlack,
      'useMbps': useMbps,
      'pingCount': pingCount,
      'workers': workers,
      'durationSec': durationSec,
      'sampleMs': sampleMs,
      'endpoints': endpoints,
      'dnsServers': dnsServers,
      'uploadEndpoint': uploadEndpoint,
      'uploadEndpoints': uploadEndpoints,
      'downloadConnections': downloadConnections,
      'downloadBlockKb': downloadBlockKb,
      'downloadRetries': downloadRetries,
      'downloadMirrors': downloadMirrors,
      'downloadDns': downloadDns,
      'downloadUserAgent': downloadUserAgent,
      'downloadDir': downloadDir,
      'downloadBind': downloadBind,
      'speedBind': speedBind,
      'downloadIpMode': downloadIpMode,
      'speedIpMode': speedIpMode,
      'downloadDnsMode': downloadDnsMode,
      'speedDnsMode': speedDnsMode,
      'ipdbUrl': ipdbUrl,
      'ipApiEndpoint': ipApiEndpoint,
      'browserHome': browserHome,
      'browserUaMode': browserUaMode,
      'browserUaCustom': browserUaCustom,
      'browserJavaScript': browserJavaScript,
      'browserSniff': browserSniff,
      'browserIntercept': browserIntercept,
      'userScriptsEnabled': userScriptsEnabled,
      'history': history.map((e) => e.toJson()).toList(),
      'downloadRecords': downloadRecords,
      'pluginSettings': pluginSettings,
      'pluginStorage': pluginStorage,
    };
    try {
      await File(_path).writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  Map<String, String> pluginSettingsOf(String id) =>
      Map<String, String>.from(pluginSettings[id] ?? const {});

  void setPluginSetting(String id, String key, String value) {
    final next = Map<String, String>.from(pluginSettings[id] ?? const {});
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    pluginSettings = {...pluginSettings, id: next};
    notifyListeners();
    unawaited(save());
  }

  String? pluginStorageGet(String key) => pluginStorage[key];

  void pluginStorageSet(String key, String value) {
    pluginStorage = {...pluginStorage, key: value};
    unawaited(save());
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    save();
    notifyListeners();
  }

  void setSeed(Color color) {
    seed = color;
    save();
    notifyListeners();
  }

  void setPureBlack(bool value) {
    pureBlack = value;
    save();
    notifyListeners();
  }

  void setPingCount(int value) {
    pingCount = value.clamp(1, 500);
    save();
    notifyListeners();
  }

  void setUnit(bool mbps) {
    useMbps = mbps;
    save();
    notifyListeners();
  }

  void setWorkers(int value) {
    workers = value.clamp(1, 64);
    save();
    notifyListeners();
  }

  void setDuration(int value) {
    durationSec = value.clamp(3, 120);
    save();
    notifyListeners();
  }

  void setSampleMs(int value) {
    sampleMs = value.clamp(100, 2000);
    save();
    notifyListeners();
  }

  void setEndpoints(List<String> value) {
    endpoints = value;
    save();
    notifyListeners();
  }

  void setDnsServers(List<String> value) {
    dnsServers = normalizeDnsList(value);
    save();
    notifyListeners();
  }

  void setDownloadBind(String value) {
    downloadBind = value.trim();
    save();
    notifyListeners();
  }

  void setSpeedBind(String value) {
    speedBind = value.trim();
    save();
    notifyListeners();
  }

  void setDownloadIpMode(String value) {
    downloadIpMode = value;
    save();
    notifyListeners();
  }

  void setSpeedIpMode(String value) {
    speedIpMode = value;
    save();
    notifyListeners();
  }

  void setDownloadDnsMode(String value) {
    downloadDnsMode = value;
    save();
    notifyListeners();
  }

  void setSpeedDnsMode(String value) {
    speedDnsMode = value;
    save();
    notifyListeners();
  }

  void setDownloadConnections(int value) {
    downloadConnections = value.clamp(1, 32);
    save();
    notifyListeners();
  }

  void setDownloadBlockKb(int value) {
    downloadBlockKb = value.clamp(64, 8192);
    save();
    notifyListeners();
  }

  void setDownloadRetries(int value) {
    downloadRetries = value.clamp(0, 10);
    save();
    notifyListeners();
  }

  void setDownloadMirrors(List<String> value) {
    downloadMirrors = value;
    save();
    notifyListeners();
  }

  void setDownloadDns(List<String> value) {
    downloadDns = normalizeDnsList(value);
    save();
    notifyListeners();
  }

  void setDownloadUserAgent(String value) {
    downloadUserAgent = value;
    save();
    notifyListeners();
  }

  void setDownloadDir(String value) {
    downloadDir = value.trim();
    save();
    notifyListeners();
  }

  void setIpdbUrl(String value) {
    ipdbUrl = value.trim();
    save();
    notifyListeners();
  }

  void setIpApiEndpoint(String value) {
    ipApiEndpoint = value.trim();
    save();
    notifyListeners();
  }

  void setBrowserSettings({
    String? home,
    String? uaMode,
    String? uaCustom,
    bool? javaScript,
    bool? sniff,
    bool? intercept,
  }) {
    if (home != null) browserHome = home.trim();
    if (uaMode != null) browserUaMode = uaMode;
    if (uaCustom != null) browserUaCustom = uaCustom.trim();
    if (javaScript != null) browserJavaScript = javaScript;
    if (sniff != null) browserSniff = sniff;
    if (intercept != null) browserIntercept = intercept;
    save();
    notifyListeners();
  }

  void setUserScriptsEnabled(bool value) {
    userScriptsEnabled = value;
    save();
    notifyListeners();
  }

  void setUploadEndpoints(List<String> value) {
    uploadEndpoints = value
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
    uploadEndpoint = uploadEndpoints.isEmpty ? '' : uploadEndpoints.first;
    save();
    notifyListeners();
  }

  void setUploadEndpoint(String value) {
    uploadEndpoint = value;
    uploadEndpoints = value.trim().isEmpty ? [] : [value.trim()];
    save();
    notifyListeners();
  }

  static String downloadRecordKey(Map<String, dynamic> record) =>
      '${record['url'] ?? ''}|${record['dir'] ?? ''}|${record['name'] ?? ''}';

  Map<String, dynamic>? findDownloadRecord(String key) {
    for (final r in downloadRecords) {
      if (downloadRecordKey(r) == key) return r;
    }
    return null;
  }

  /// 新增或更新下载记录；persist=false 时只改内存，适合高频进度刷新。
  void upsertDownloadRecord(
    Map<String, dynamic> record, {
    bool persist = true,
    bool notify = false,
  }) {
    final key = downloadRecordKey(record);
    final index = downloadRecords.indexWhere(
      (r) => downloadRecordKey(r) == key,
    );
    if (index >= 0) {
      downloadRecords[index] = record;
    } else {
      downloadRecords.insert(0, record);
      if (downloadRecords.length > 200)
        downloadRecords.removeRange(200, downloadRecords.length);
    }
    if (persist) save();
    if (notify) notifyListeners();
  }

  void removeDownloadRecord(String key) {
    downloadRecords.removeWhere((r) => downloadRecordKey(r) == key);
    save();
  }

  /// 批量移除记录（一次落盘），用于清理已完成任务。
  int removeDownloadRecords(Iterable<String> keys) {
    final set = keys.toSet();
    if (set.isEmpty) return 0;
    final before = downloadRecords.length;
    downloadRecords.removeWhere((r) => set.contains(downloadRecordKey(r)));
    final removed = before - downloadRecords.length;
    if (removed > 0) save();
    return removed;
  }

  void updateDownloadRecordProgress(
    String key,
    Map<String, dynamic> patch, {
    bool persist = false,
  }) {
    final index = downloadRecords.indexWhere(
      (r) => downloadRecordKey(r) == key,
    );
    if (index < 0) return;
    final next = {...downloadRecords[index], ...patch};
    downloadRecords[index] = next;
    if (persist) save();
  }

  void addHistory(HistoryRecord record) {
    history.insert(0, record);
    if (history.length > 80) history.removeRange(80, history.length);
    save();
    notifyListeners();
  }

  void clearHistory() {
    history = [];
    save();
    notifyListeners();
  }

  double get displayFactor => useMbps ? 1.0 : 1 / 8.0;
  String get displayUnit => useMbps ? 'Mbps' : 'MB/s';
  String displaySpeed(double mbps) => formatMbps(mbps * displayFactor);
}

class AppScope extends InheritedNotifier<AppStore> {
  const AppScope({super.key, required AppStore store, required super.child})
    : super(notifier: store);

  static AppStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found');
    return scope!.notifier!;
  }
}
