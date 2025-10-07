// -------- UpdateGate (Android + iOS, unified + platform-specific RC keys) ----
import 'dart:io';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:in_app_update/in_app_update.dart' as play; // Android only

class UpdateGate extends StatefulWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});
  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  bool _checking = true;
  bool _forceUpdate = false;
  bool _softUpdate = false;
  String? _storeUrl; // used on iOS; Android uses market://
  String _message = 'Please update the app';

  // for debug overlay
  int _currentBuild = 0, _minBuild = 0, _recBuild = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

// Prefer a platform-specific key if it has a non-empty/non-zero value;
// otherwise fall back to the unified key. No enum needed.
  int _rcInt(FirebaseRemoteConfig rc, List<String> keys, int def) {
    for (final k in keys) {
      final s = rc.getValue(k).asString().trim();
      final n = int.tryParse(s);
      if (n != null && n != 0) return n; // treat 0 as "no gate" / default
    }
    // If all were 0/empty, return 0 (or def)
    return def;
  }

  String _rcString(FirebaseRemoteConfig rc, List<String> keys, String def) {
    for (final k in keys) {
      final s = rc.getValue(k).asString().trim();
      if (s.isNotEmpty) return s;
    }
    return def;
  }

  Future<void> _check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;
      _currentBuild = currentBuild;

      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        // fetch fresh every run in debug; cache a bit in release
        minimumFetchInterval:
            kReleaseMode ? const Duration(minutes: 30) : Duration.zero,
      ));
      await rc.setDefaults(const {
        'min_supported_build': 0,
        'recommended_build': 0,
        'latest_store_url': '',
        'update_message': 'Please update the app',
      });

      final fetched = await rc.fetchAndActivate();

      // --- Read values (prefer platform-specific) ---
      final isAndroid = Platform.isAndroid;
      final minBuild = _rcInt(
        rc,
        isAndroid
            ? ['min_supported_build_android', 'min_supported_build']
            : ['min_supported_build_ios', 'min_supported_build'],
        0,
      );
      final recBuild = _rcInt(
        rc,
        isAndroid
            ? ['recommended_build_android', 'recommended_build']
            : ['recommended_build_ios', 'recommended_build'],
        0,
      );
      final url = _rcString(
        rc,
        isAndroid
            ? [
                'latest_store_url_android',
                'latest_store_url'
              ] // usually unused on Android
            : ['latest_store_url_ios', 'latest_store_url'],
        '',
      );
      final msg = _rcString(
        rc,
        isAndroid
            ? ['update_message_android', 'update_message']
            : ['update_message_ios', 'update_message'],
        'Please update the app',
      );

      _minBuild = minBuild;
      _recBuild = recBuild;

      final force = currentBuild < minBuild;
      final soft = !force && currentBuild < recBuild;

      // Optional: try Play in-app updates when available
      if (isAndroid && (force || soft)) {
        _tryAndroidInAppUpdate(immediate: force);
      }

      if (!mounted) return;
      setState(() {
        _forceUpdate = force;
        _softUpdate = soft;
        _storeUrl = url.isEmpty ? null : url;
        _message = msg;
        _checking = false;
      });

      // Diagnostics: visible in debug run/logcat/Xcode
      // (In release from stores you won’t usually see these.)
      // ignore: avoid_print
      print(
          '🔧 RC fetched=$fetched  project=${Firebase.app().options.projectId}');
      // ignore: avoid_print
      print(
          '🔧 build=$currentBuild  min=$minBuild  rec=$recBuild  url="${_storeUrl ?? ''}"');
      // ignore: avoid_print
      print('🔧 result -> force=$_forceUpdate soft=$_softUpdate');
    } catch (e, st) {
      // ignore: avoid_print
      print('⚠️ UpdateGate error: $e\n$st');
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _tryAndroidInAppUpdate({required bool immediate}) async {
    try {
      final info = await play.InAppUpdate.checkForUpdate();
      if (info.updateAvailability == play.UpdateAvailability.updateAvailable) {
        if (immediate && info.immediateUpdateAllowed) {
          await play.InAppUpdate.performImmediateUpdate();
        } else if (!immediate && info.flexibleUpdateAllowed) {
          await play.InAppUpdate.startFlexibleUpdate();
          await play.InAppUpdate.completeFlexibleUpdate();
        }
      }
    } catch (_) {/* fall back to store */}
  }

  Future<void> _openStore() async {
    if (Platform.isAndroid) {
      final pkg = (await PackageInfo.fromPlatform()).packageName;
      final market = Uri.parse('market://details?id=$pkg');
      final web =
          Uri.parse('https://play.google.com/store/apps/details?id=$pkg');
      if (await canLaunchUrl(market)) {
        await launchUrl(market, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
      return;
    }
    // iOS needs your App Store URL
    if (_storeUrl == null || _storeUrl!.isEmpty) return;
    final itms = Uri.parse(_storeUrl!.replaceFirst('https://', 'itms-apps://'));
    final https = Uri.parse(_storeUrl!);
    if (await canLaunchUrl(itms)) {
      await launchUrl(itms, mode: LaunchMode.externalApplication);
    } else {
      await launchUrl(https, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_forceUpdate) {
      return _ForceUpdateScreen(message: _message, onUpdate: _openStore);
    }

    return Stack(
      children: [
        widget.child,
        if (_softUpdate)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                elevation: 6,
                color: Colors.orange.shade700,
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(12)),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.system_update, color: Colors.white),
                    const SizedBox(width: 10),
                    Flexible(
                        child: Text(_message,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600))),
                    const SizedBox(width: 12),
                    TextButton(
                        onPressed: _openStore,
                        child: const Text('Update',
                            style: TextStyle(color: Colors.white))),
                    TextButton(
                        onPressed: () => setState(() => _softUpdate = false),
                        child: const Text('Later',
                            style: TextStyle(color: Colors.white70))),
                  ]),
                ),
              ),
            ),
          ),

        // Tiny debug overlay (only in debug/profile)
        if (!kReleaseMode)
          Positioned(
            left: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                    'build=$_currentBuild • min=$_minBuild • rec=$_recBuild',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ),
      ],
    );
  }
}

class _ForceUpdateScreen extends StatelessWidget {
  final String message;
  final VoidCallback onUpdate;
  const _ForceUpdateScreen({required this.message, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              colors: [Color(0xFF567D46), Color(0xFF365A38)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.system_update, size: 64),
                  const SizedBox(height: 12),
                  Text('Update Required',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 16),
                  SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                          onPressed: onUpdate,
                          child: const Text('Update Now'))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
