import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与 Rust core 的 JSON-over-FFI 桥。
class Core {
  Core._();

  static final Core i = Core._();

  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>)? _call;
  ffi.Pointer<ffi.Uint8> Function()? _version;
  void Function(ffi.Pointer<ffi.Uint8>)? _free;
  ffi.Pointer<ffi.Uint8> Function(int)? _malloc;
  void Function(ffi.Pointer<ffi.Uint8>)? _dealloc;

  bool get ready => _call != null;

  void init() {
    if (_call != null) return;
    _lib = ffi.DynamicLibrary.open('libnetpulse_core.so');
    _call = _lib!.lookupFunction<
        ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>),
        ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>)>('np_call');
    _version = _lib!.lookupFunction<ffi.Pointer<ffi.Uint8> Function(),
        ffi.Pointer<ffi.Uint8> Function()>('np_version');
    _free = _lib!.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Uint8>),
        void Function(ffi.Pointer<ffi.Uint8>)>('np_free');
    _malloc = _lib!.lookupFunction<ffi.Pointer<ffi.Uint8> Function(ffi.Uint32),
        ffi.Pointer<ffi.Uint8> Function(int)>('np_alloc');
    _dealloc = _lib!.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Uint8>),
        void Function(ffi.Pointer<ffi.Uint8>)>('np_dealloc');
  }

  Map<String, dynamic> call(String cmd, [Map<String, dynamic> args = const {}]) {
    init();
    final req = utf8.encode(jsonEncode({'cmd': cmd, 'args': args}));
    final ptr = _malloc!(req.length + 1).cast<ffi.Uint8>();
    for (var i = 0; i < req.length; i++) {
      ptr[i] = req[i];
    }
    ptr[req.length] = 0;
    ffi.Pointer<ffi.Uint8> respPtr;
    try {
      respPtr = _call!(ptr);
    } finally {
      _dealloc!(ptr);
    }
    try {
      final text = _readCString(respPtr);
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      _free!(respPtr);
    }
  }

  String _readCString(ffi.Pointer<ffi.Uint8> p) {
    final bytes = p.cast<ffi.Uint8>();
    var len = 0;
    while (len < 8 * 1024 * 1024 && bytes[len] != 0) {
      len++;
    }
    final data = Uint8List(len);
    for (var i = 0; i < len; i++) {
      data[i] = bytes[i];
    }
    return utf8.decode(data, allowMalformed: true);
  }

  String version() {
    init();
    final p = _version!();
    try {
      return _readCString(p);
    } finally {
      _free!(p);
    }
  }

  /// 在后台 isolate 调用 core，避免 dl_list / dl_detail 这类同步 FFI
  /// 在下载高负载时卡住 Flutter UI 线程。
  static Future<Map<String, dynamic>> callAsync(
    String cmd, [Map<String, dynamic> args = const {}]) {
    return Isolate.run(() {
      Core.i.init();
      return Core.i.call(cmd, args);
    });
  }

  String start(String cmd, Map<String, dynamic> args) {
    final r = call(cmd, args);
    if (r['ok'] != true) {
      throw CoreException(r['error']?.toString() ?? '未知错误');
    }
    final data = r['data'];
    if (data is Map && data['task_id'] is String) {
      return data['task_id'] as String;
    }
    throw const CoreException('缺少 task_id');
  }

  Map<String, dynamic>? poll(String id) {
    final r = call('task_poll', {'id': id});
    if (r['ok'] != true) return null;
    return (r['data'] as Map?)?.cast<String, dynamic>();
  }

  void cancel(String id) => call('task_cancel', {'id': id});

  void dispose(String id) => call('task_dispose', {'id': id});
}

class CoreException implements Exception {
  const CoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个运行中的 core 任务：自动轮询、缓存事件、暴露状态。
class CoreTask extends ChangeNotifier {
  CoreTask(this.kind, this.id);

  factory CoreTask.start(String kind, Map<String, dynamic> args) {
    final id = Core.i.start('start_$kind', args);
    final t = CoreTask(kind, id);
    t._startPolling();
    return t;
  }

  final String kind;
  final String id;
  final List<Map<String, dynamic>> events = [];
  final List<Map<String, dynamic>> samples = [];
  Map<String, dynamic>? summary;
  String status = 'running';
  String? error;
  Timer? _timer;
  int _lastSample = 0;

  bool get running => status == 'running' || status == 'cancelling';
  bool get stopping => status == 'cancelling';

  void _startPolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 110), (_) => _poll());
  }

  void _poll() {
    final data = Core.i.poll(id);
    if (data == null) return;
    final incoming = (data['events'] as List? ?? const []);
    var changed = false;
    for (final raw in incoming) {
      if (raw is! Map) continue;
      final e = raw.cast<String, dynamic>();
      events.add(e);
      changed = true;
      if (e['type'] == 'sample') {
        samples.add(e);
        if (samples.length > 2400) samples.removeRange(0, samples.length - 2400);
      }
      if (e['type'] == 'done' && e['summary'] is Map) {
        summary = (e['summary'] as Map).cast<String, dynamic>();
      }
      if (e['type'] == 'error' && e['message'] is String) {
        error ??= e['message'] as String;
      }
    }
    final nextStatus = data['status']?.toString() ?? status;
    final s = data['summary'];
    if (s is Map) summary = s.cast<String, dynamic>();
    if (nextStatus != status) {
      status = nextStatus;
      changed = true;
    }
    if (changed) notifyListeners();
    if (!running) {
      _timer?.cancel();
      _timer = null;
      _lastSample = samples.length;
      notifyListeners();
    }
  }

  double get lastMbps {
    if (samples.isEmpty) return 0;
    final v = samples.last['mbps'];
    return v is num ? v.toDouble() : 0;
  }

  double get lastSmoothMbps {
    if (samples.isEmpty) return 0;
    final v = samples.last['mbps_smooth'] ?? samples.last['mbps'];
    return v is num ? v.toDouble() : 0;
  }

  int get newSampleCount => samples.length - _lastSample;

  void stop() {
    Core.i.cancel(id);
    status = 'cancelling';
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (running) Core.i.cancel(id);
    // 释放 Rust 侧任务记录，避免每次测速/诊断都留下一个 Task。
    try {
      Core.i.dispose(id);
    } catch (_) {}
    super.dispose();
  }
}

/// 原生侧信息（路径 / 网络）。
class NativeInfo {
  static const MethodChannel _channel = MethodChannel('netpulse/native');

  /// 由系统分享 / 外部链接推入待处理的 URL。
  static final ValueNotifier<String?> pushedLink = ValueNotifier<String?>(null);

  static void listenPush() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pushLink' && call.arguments is String) {
        pushedLink.value = call.arguments as String;
      }
      return null;
    });
  }

  static Future<String?> takeInitialLink() async {
    try {
      return await _channel.invokeMethod<String>('initialLink');
    } catch (_) {
      return null;
    }
  }

  static String filesDir = '';
  static String cacheDir = '';
  static String nativeLibDir = '';
  static int sdkInt = 0;
  static bool iperfAvailable = false;
  static String networkType = '未知';
  static String localIp = '';
  static int ipPrefix = 0;
  static String netmask = '';
  static String gateway = '';
  static String gateway6 = '';
  static String ipv6 = '';
  static String interfaceName = '';
  static String macAddress = '';
  static int mtu = 0;
  static int linkDownKbps = 0;
  static int linkUpKbps = 0;
  static List<String> systemDns = [];
  static List<Map<String, String>> interfaces = [];
  static bool validated = false;
  static bool metered = false;
  static bool vpn = false;
  static bool macHidden = false;
  static String privateDns = '';
  static String linkSource = '';
  static String wifiSsid = '';
  static String wifiBssid = '';
  static String wifiStandard = '';
  static int wifiFrequency = 0;
  static int wifiRssi = 0;
  static Map<String, dynamic> lanActive = {};
  static List<Map<String, dynamic>> lanNetworks = [];
  static List<Map<String, dynamic>> lanInterfaces = [];
  static bool initialized = false;

  static Future<void> load() async {
    if (initialized) return;
    try {
      final paths = await _channel.invokeMapMethod<String, dynamic>('paths');
      filesDir = paths?['files'] as String? ?? '';
      cacheDir = paths?['cache'] as String? ?? '';
      nativeLibDir = paths?['nativeLib'] as String? ?? '';
      sdkInt = (paths?['sdkInt'] as num?)?.toInt() ?? 0;
      iperfAvailable = paths?['iperf'] == true;
    } catch (_) {
      filesDir = Directory.systemTemp.path;
    }
    await _reloadNetwork();
    initialized = true;
  }

  static Future<void> refreshNetwork() async {
    await _reloadNetwork();
  }

  static Future<void> _reloadNetwork() async {
    try {
      final lan = await _channel.invokeMapMethod<String, dynamic>('lanInfo');
      if (lan != null) {
        _applyLanInfo(lan);
        return;
      }
    } catch (_) {}
    try {
      final net = await _channel.invokeMapMethod<String, dynamic>('network');
      _applyNetwork(net);
    } catch (_) {}
    await loadInterfaces();
  }

  static List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  static void _applyLanInfo(Map<String, dynamic> lan) {
    final active = lan['active'];
    if (active is Map) {
      lanActive = active.cast<String, dynamic>();
      _applyNetwork(lanActive);
    }
    lanNetworks = _mapList(lan['networks']);
    lanInterfaces = _mapList(lan['interfaces']);
    final flat = <Map<String, String>>[];
    for (final it in lanInterfaces) {
      final addresses = it['addresses'];
      if (addresses is! List) continue;
      for (final addr in addresses) {
        if (addr is! Map) continue;
        final ip = addr['ip']?.toString() ?? '';
        if (ip.isEmpty) continue;
        flat.add({
          'name': it['name']?.toString() ?? '',
          'ip': ip,
          'prefix': addr['prefix']?.toString() ?? '',
          'family': addr['family']?.toString() ?? '',
          'loopback': it['loopback']?.toString() ?? 'false',
          'virtual': it['virtual']?.toString() ?? 'false',
          'mac': it['mac']?.toString() ?? '',
        });
      }
    }
    interfaces = flat;
  }

  static void _applyNetwork(Map<String, dynamic>? net) {
    if (net == null) return;
    networkType = net['type']?.toString() ?? '未知';
    localIp = net['ip']?.toString() ?? '';
    ipPrefix = (net['prefix'] as num? ?? 0).toInt();
    netmask = net['netmask']?.toString() ?? '';
    gateway = net['gateway']?.toString() ?? '';
    gateway6 = net['gateway6']?.toString() ?? '';
    ipv6 = net['ipv6']?.toString() ?? '';
    interfaceName = net['interface']?.toString() ?? '';
    macAddress = net['mac']?.toString() ?? '';
    mtu = (net['mtu'] as num? ?? 0).toInt();
    linkDownKbps = (net['linkDownKbps'] as num? ?? 0).toInt();
    linkUpKbps = (net['linkUpKbps'] as num? ?? 0).toInt();
    validated = net['validated'] == true;
    metered = net['metered'] == true;
    vpn = net['vpn'] == true;
    macHidden = net['macHidden'] == true;
    privateDns = net['privateDns']?.toString() ?? '';
    linkSource = net['linkSource']?.toString() ?? '';
    wifiSsid = net['wifiSsid']?.toString() ?? '';
    wifiBssid = net['wifiBssid']?.toString() ?? '';
    wifiStandard = net['wifiStandard']?.toString() ?? '';
    wifiFrequency = (net['wifiFrequency'] as num? ?? 0).toInt();
    wifiRssi = (net['wifiRssi'] as num? ?? 0).toInt();
    final dns = net['dns'];
    if (dns is List) systemDns = dns.map((e) => e.toString()).toList();
  }

  static Future<void> loadInterfaces() async {
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('interfaces');
      interfaces = (list ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>().map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
    } catch (_) {}
  }

  /// 选择文本文件（TOML 等），返回文件内容。
  static Future<String?> pickTextFile() async {
    try {
      return await _channel.invokeMethod<String>('pickTextFile');
    } catch (_) {
      return null;
    }
  }

  /// 调起系统“另存为”，写入文本；返回目标 URI 或 null。
  static Future<String?> saveTextFile(String text, String name) async {
    try {
      return await _channel.invokeMethod<String>('saveTextFile', {'text': text, 'name': name});
    } catch (_) {
      return null;
    }
  }

  /// 确保默认 Download/NetPulse 目录存在；未授权“所有文件访问权限”时引导授权。
  static Future<String?> prepareDownloadDir() async {
    try {
      return await _channel.invokeMethod<String>('prepareDownloadDir');
    } catch (_) {
      return null;
    }
  }

  /// 调起系统文件管理器选择目录，返回绝对路径；部分系统需要“所有文件访问权限”。
  static Future<String?> selectDirectory() async {
    try {
      return await _channel.invokeMethod<String>('selectDirectory');
    } catch (_) {
      return null;
    }
  }

  static String get iperfPath => nativeLibDir.isEmpty
      ? ''
      : '$nativeLibDir/libiperf3.so';

  static Future<void> openUrl(String url) async {
    try {
      await _channel.invokeMethod('openUrl', {'url': url});
    } catch (_) {}
  }
}
