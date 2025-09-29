import 'dart:io';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> with WidgetsBindingObserver {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  Orientation? _lastOrientation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final orientation = MediaQuery.of(context).orientation;

    // Load once, and reload only on orientation change (adaptive banners).
    if (_bannerAd == null || _lastOrientation != orientation) {
      _lastOrientation = orientation;
      _loadAdaptiveBanner();
    }
  }

  Future<void> _loadAdaptiveBanner() async {
    // Dispose any existing ad before loading a new one.
    await _bannerAd?.dispose();
    _bannerAd = null;
    setState(() => _isLoaded = false);

    // Width in logical pixels (Flutter logical px ≈ dp), truncated to int.
    final width = MediaQuery.of(context).size.width.truncate();

    final size =
        await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (size == null) {
      debugPrint('Unable to get adaptive banner size.');
      return;
    }

    // Test IDs in debug/profile, real IDs in release.
    final adUnitId = Platform.isAndroid
        ? (kReleaseMode
            ? 'ca-app-pub-3773871623541431/1736402547' // real Android banner unit
            : 'ca-app-pub-3940256099942544/6300978111') // Google test Android banner
        : (kReleaseMode
            ? 'ca-app-pub-3773871623541431/5447708694' // real iOS banner unit
            : 'ca-app-pub-3940256099942544/2934735716'); // Google test iOS banner

    final ad = BannerAd(
      size: size,
      adUnitId: adUnitId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) => setState(() => _isLoaded = true),
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('BannerAd failed to load: $error');
        },
      ),
    );

    _bannerAd = ad..load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded || _bannerAd == null) return const SizedBox.shrink();
    return SizedBox(
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }
}
