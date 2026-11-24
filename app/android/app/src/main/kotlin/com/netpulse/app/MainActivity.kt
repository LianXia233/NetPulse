package com.netpulse.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingDirResult: MethodChannel.Result? = null
    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingSaveText: String? = null
    private var pendingPrepResult: MethodChannel.Result? = null

    private val reqDir = 1001
    private val reqPick = 1002
    private val reqSave = 1003
    private val reqStorage = 1004
    private val reqWrite = 1005

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "netpulse/native")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "paths" -> result.success(
                    mapOf(
                        "files" to filesDir.absolutePath,
                        "cache" to cacheDir.absolutePath,
                        "nativeLib" to applicationInfo.nativeLibraryDir,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "iperf" to File(applicationInfo.nativeLibraryDir, "libiperf3.so")
                            .let { it.isFile && it.canExecute() }
                    )
                )
                "network" -> result.success(networkInfo())
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("bad_url", "URL 为空", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }
                }
                "initialLink" -> result.success(takeLink(intent))
                "selectDirectory" -> selectDirectory(result)
                "prepareDownloadDir" -> prepareDownloadDir(result)
                "interfaces" -> result.success(localInterfaces())
                "lanInfo" -> result.success(lanInfo())
                "pickTextFile" -> {
                    pendingFileResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf(
                                    "text/plain",
                                    "text/x-toml",
                                    "application/toml",
                                    "application/octet-stream"
                                )
                            )
                        }
                        startActivityForResult(intent, reqPick)
                    } catch (e: Exception) {
                        pendingFileResult = null
                        result.error("picker_failed", e.message, null)
                    }
                }
                "saveTextFile" -> {
                    val text = call.argument<String>("text") ?: ""
                    val name = call.argument<String>("name") ?: "netpulse-speed.toml"
                    pendingFileResult = result
                    pendingSaveText = text
                    try {
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        startActivityForResult(intent, reqSave)
                    } catch (e: Exception) {
                        pendingFileResult = null
                        pendingSaveText = null
                        result.error("saver_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = takeLink(intent)
        if (link != null) channel?.invokeMethod("pushLink", link)
    }

    private fun ensureDownloadDir(): String? {
        return try {
            val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val dir = File(base, "NetPulse")
            if (!dir.exists()) dir.mkdirs()
            if (dir.isDirectory && dir.canWrite()) dir.absolutePath else null
        } catch (_: Exception) {
            null
        }
    }

    /// Android 7–10 在无法写公共目录时退回应用专属目录（无需权限，卸载即清理）。
    private fun ensureAppDownloadDir(): String {
        val base = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
        val dir = File(base, "NetPulse")
        dir.mkdirs()
        return dir.absolutePath
    }

    private fun hasWritePermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestWritePermission(result: MethodChannel.Result, forDirectoryPicker: Boolean) {
        if (forDirectoryPicker) pendingDirResult = result else pendingPrepResult = result
        requestPermissions(
            arrayOf(
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ),
            reqWrite
        )
    }

    private fun prepareDownloadDir(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R && !hasWritePermission()) {
            requestWritePermission(result, forDirectoryPicker = false)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            if (pendingPrepResult != null) {
                result.error("busy", "正在等待存储权限", null)
                return
            }
            pendingPrepResult = result
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivityForResult(intent, reqStorage)
            } catch (e: Exception) {
                pendingPrepResult = null
                result.error("permission_failed", e.message, null)
            }
            return
        }
        val path = ensureDownloadDir() ?: ensureAppDownloadDir()
        result.success(path)
    }

    private fun selectDirectory(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R && !hasWritePermission()) {
            requestWritePermission(result, forDirectoryPicker = true)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
                result.error("need_permission", "请先授予“所有文件访问权限”，再回来选择目录", null)
            } catch (e: Exception) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    result.error("need_permission", "请先授予“所有文件访问权限”，再回来选择目录", null)
                } catch (e2: Exception) {
                    result.error("permission_failed", e2.message, null)
                }
            }
            return
        }
        pendingDirResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            }
            startActivityForResult(intent, reqDir)
        } catch (e: Exception) {
            pendingDirResult = null
            result.error("picker_failed", e.message, null)
        }
    }

    private fun treeUriToPath(uri: Uri): String? {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(uri)
            val parts = docId.split(":", limit = 2)
            if (parts.size != 2) return null
            val volume = parts[0]
            val relative = parts[1].trim('/')
            val base = if (volume.equals("primary", ignoreCase = true)) {
                Environment.getExternalStorageDirectory().absolutePath
            } else {
                "/storage/$volume"
            }
            val path = if (relative.isEmpty()) base else "$base/$relative"
            val dir = File(path)
            if (dir.isDirectory && (dir.canWrite() || Environment.isExternalStorageManager())) path else null
        } catch (_: Exception) {
            null
        }
    }

    private fun localInterfaces(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        try {
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.isUp) continue
                for (addr in nif.inetAddresses) {
                    val ip = addr.hostAddress ?: continue
                    if (ip.contains('%')) continue
                    out.add(
                        mapOf(
                            "name" to nif.name,
                            "ip" to ip,
                            "loopback" to nif.isLoopback,
                            "virtual" to nif.isVirtual
                        )
                    )
                }
            }
        } catch (_: Exception) {}
        return out
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != reqWrite) return
        val prep = pendingPrepResult
        pendingPrepResult = null
        if (prep != null) {
            if (hasWritePermission()) prepareDownloadDir(prep)
            else prep.success(ensureAppDownloadDir())
            return
        }
        val dir = pendingDirResult
        pendingDirResult = null
        if (dir != null) {
            if (!hasWritePermission()) {
                dir.error("need_permission", "未授予存储权限，无法选择公共目录", null)
            } else {
                selectDirectory(dir)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqStorage) {
            val result = pendingPrepResult
            pendingPrepResult = null
            if (result == null) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                // 用户拒绝“所有文件访问”时退回应用专属目录，保证下载功能可用。
                result.success(ensureAppDownloadDir())
            } else {
                result.success(ensureDownloadDir() ?: ensureAppDownloadDir())
            }
            return
        }
        if (requestCode == reqDir) {
            val result = pendingDirResult
            pendingDirResult = null
            if (result == null) return
            if (resultCode != android.app.Activity.RESULT_OK) {
                result.error("cancelled", "未选择目录", null)
                return
            }
            val uri = data?.data
            if (uri == null) {
                result.error("no_uri", "未返回目录 URI", null)
                return
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {}
            val path = treeUriToPath(uri)
            if (path == null) {
                result.error("unsupported", "该目录无法映射为可写路径，请选择内部存储或 SD 卡目录", null)
            } else {
                result.success(path)
            }
            return
        }
        if (requestCode == reqPick) {
            val result = pendingFileResult
            pendingFileResult = null
            if (result == null) return
            if (resultCode != android.app.Activity.RESULT_OK || data?.data == null) {
                result.error("cancelled", "未选择文件", null)
                return
            }
            try {
                val text = contentResolver.openInputStream(data.data!!)?.bufferedReader()?.use { it.readText() } ?: ""
                result.success(text)
            } catch (e: Exception) {
                result.error("read_failed", e.message, null)
            }
            return
        }
        if (requestCode == reqSave) {
            val result = pendingFileResult
            val text = pendingSaveText
            pendingFileResult = null
            pendingSaveText = null
            if (result == null) return
            if (resultCode != android.app.Activity.RESULT_OK || data?.data == null) {
                result.error("cancelled", "未选择保存位置", null)
                return
            }
            try {
                contentResolver.openOutputStream(data.data!!)?.bufferedWriter()?.use { it.write(text ?: "") }
                result.success(data.data.toString())
            } catch (e: Exception) {
                result.error("write_failed", e.message, null)
            }
        }
    }

    private fun takeLink(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }?.trim()?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
    }

    private fun transportOf(caps: NetworkCapabilities?): String = when {
        caps == null -> "未知"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "蜂窝网络"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "以太网"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "蓝牙"
        else -> "其他"
    }

    private fun readLinkSpeed(name: String): Int {
        return try {
            File("/sys/class/net/$name/speed").readText().trim().toIntOrNull() ?: 0
        } catch (_: Exception) {
            0
        }
    }

    /// 一次返回活动网络、全部已注册网络和全部本机网卡的详细参数。
    private fun lanInfo(): Map<String, Any?> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val networks = ArrayList<Map<String, Any?>>()
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            val lp = cm.getLinkProperties(network) ?: continue
            val addresses = lp.linkAddresses.map { link ->
                mapOf(
                    "ip" to (link.address.hostAddress ?: ""),
                    "prefix" to link.prefixLength,
                    "family" to if (link.address is Inet4Address) "v4" else "v6",
                    "broadcast" to ""
                )
            }
            val gateway = lp.routes
                .firstOrNull { it.isDefaultRoute && it.gateway != null }
                ?.gateway?.hostAddress ?: ""
            networks.add(
                mapOf(
                    "id" to network.toString(),
                    "transport" to transportOf(caps),
                    "interface" to (lp.interfaceName ?: ""),
                    "addresses" to addresses,
                    "dns" to lp.dnsServers.mapNotNull { it.hostAddress },
                    "gateway" to gateway,
                    "mtu" to lp.mtu,
                    "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                    "internet" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                    "metered" to !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                    "vpn" to caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
                    "downKbps" to caps.linkDownstreamBandwidthKbps,
                    "upKbps" to caps.linkUpstreamBandwidthKbps,
                    "privateDns" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        lp.privateDnsServerName ?: ""
                    } else {
                        ""
                    },
                    "httpProxy" to (lp.httpProxy?.toString() ?: "")
                )
            )
        }

        val interfaces = ArrayList<Map<String, Any?>>()
        for (nif in NetworkInterface.getNetworkInterfaces()) {
            val addresses = nif.interfaceAddresses.mapNotNull { ia ->
                val ip = ia.address?.hostAddress ?: return@mapNotNull null
                mapOf(
                    "ip" to ip,
                    "prefix" to ia.networkPrefixLength.toInt(),
                    "family" to if (ia.address is Inet4Address) "v4" else "v6",
                    "broadcast" to (ia.broadcast?.hostAddress ?: "")
                )
            }
            val mac = try {
                nif.hardwareAddress?.joinToString(":") { b -> "%02X".format(b) } ?: ""
            } catch (_: Exception) {
                ""
            }
            interfaces.add(
                mapOf(
                    "name" to nif.name,
                    "index" to nif.index,
                    "up" to nif.isUp,
                    "loopback" to nif.isLoopback,
                    "virtual" to nif.isVirtual,
                    "pointToPoint" to nif.isPointToPoint,
                    "multicast" to nif.supportsMulticast(),
                    "mac" to mac,
                    "mtu" to nif.mtu,
                    "speedMbps" to readLinkSpeed(nif.name),
                    "addresses" to addresses
                )
            )
        }
        return mapOf(
            "active" to networkInfo(),
            "networks" to networks,
            "interfaces" to interfaces
        )
    }

    private fun prefixToMask(prefix: Int): String {
        val m = if (prefix == 0) 0L else (0xffffffffL shl (32 - prefix)) and 0xffffffffL
        return listOf(24, 16, 8, 0).joinToString(".") { shift ->
            ((m shr shift) and 0xff).toString()
        }
    }

    private fun networkInfo(): Map<String, Any?> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork
        val caps = cm.getNetworkCapabilities(network)
        val lp: LinkProperties? = cm.getLinkProperties(network)
        val type = when {
            caps == null -> "未知"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "蜂窝网络"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "以太网"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
            else -> "其他"
        }
        val v4Link = lp?.linkAddresses?.firstOrNull { it.address is Inet4Address }
        val ip = v4Link?.address?.hostAddress ?: ""
        val prefix = v4Link?.prefixLength ?: 0
        val netmask = if (prefix > 0) prefixToMask(prefix) else ""
        val ipv6 = lp?.linkAddresses
            ?.mapNotNull { it.address }
            ?.filterIsInstance<Inet6Address>()
            ?.mapNotNull { it.hostAddress }
            ?.filter { !it.contains('%') && !it.startsWith("fe80") }
            ?.take(2)
            ?.joinToString(", ") ?: ""
        val gateway = lp?.routes
            ?.firstOrNull { it.isDefaultRoute && it.gateway != null }
            ?.gateway?.hostAddress ?: ""
        val ifName = lp?.interfaceName ?: ""
        val mac = try {
            NetworkInterface.getByName(ifName)?.hardwareAddress
                ?.joinToString(":") { b -> "%02X".format(b) } ?: ""
        } catch (_: Exception) { "" }
        val dns = lp?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList<String>()
        val hasInternet = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ?: false
        return mapOf(
            "type" to type,
            "ip" to ip,
            "prefix" to prefix,
            "netmask" to netmask,
            "gateway" to gateway,
            "ipv6" to ipv6,
            "interface" to ifName,
            "mac" to mac,
            "mtu" to (lp?.mtu ?: 0),
            "dns" to dns,
            "online" to hasInternet,
            "linkDownKbps" to (caps?.linkDownstreamBandwidthKbps ?: 0),
            "linkUpKbps" to (caps?.linkUpstreamBandwidthKbps ?: 0),
            "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ?: false),
            "metered" to (caps?.let { !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) } ?: false),
            "vpn" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ?: false),
            "privateDns" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lp?.privateDnsServerName ?: ""
            } else {
                ""
            }
        )
    }
}
