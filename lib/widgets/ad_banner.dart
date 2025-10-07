import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

typedef ConsentReady = Future<bool>
    Function(); // optional: wait for UMP/consent

class AdBanner extends StatefulWidget {
  const AdBanner({
    super.key,
    this.waitForConsent, // pass your consent initializer if you have one
    // Your real units in release; Google sample IDs otherwise
    this.androidUnitRelease = 'ca-app-pub-3773871623541431/1736402547',
    this.iosUnitRelease = 'ca-app-pub-3773871623541431/5447708694',
  });

  final ConsentReady? waitForConsent;
  final String androidUnitRelease;
  final String iosUnitRelease;

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> with WidgetsBindingObserver {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  Orientation? _lastOrientation;
  int _retry = 0;
  bool _initializing = false;

  String get _adUnitId {
    if (!kReleaseMode) {
      return Platform.isAndroid
          ? 'ca-app-pub-3940256099942544/6300978111' // SAMPLE Android
          : 'ca-app-pub-3940256099942544/2934735716'; // SAMPLE iOS
    }
    return Platform.isAndroid
        ? widget.androidUnitRelease
        : widget.iosUnitRelease;
  }

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

  Future<void> _ensureInitAndConsent() async {
    if (_initializing) return;
    _initializing = true;
    try {
      if (widget.waitForConsent != null) {
        await widget.waitForConsent!(); // make sure UMP ran
      }
      await MobileAds.instance.initialize();
    } catch (_) {
      // ignore; we'll retry on load
    } finally {
      _initializing = false;
    }
  }

  AdRequest _buildRequest({required bool nonPersonalized}) {
    return AdRequest(
      nonPersonalizedAds: nonPersonalized,
      // You can also force via extras: {'npa': nonPersonalized ? '1' : '0'}
      keywords: const ['dogs', 'parks', 'pets'],
      contentUrl: 'https://inthepark.dog',
    );
  }

  Future<void> _loadAdaptiveBanner() async {
    await _disposeBanner();
    setState(() {
      _isLoaded = false;
      _retry = 0;
    });

    await _ensureInitAndConsent();

    final width = MediaQuery.of(context).size.width.truncate();
    final size =
        await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (size == null) {
      debugPrint('Unable to get adaptive banner size.');
      _scheduleRetry(); // try again later; sometimes returns null early
      return;
    }

    await _tryLoad(size, nonPersonalized: false);
  }

  Future<void> _tryLoad(AdSize size, {required bool nonPersonalized}) async {
    final ad = BannerAd(
      size: size,
      adUnitId: _adUnitId,
      request: _buildRequest(nonPersonalized: nonPersonalized),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() {
            _bannerAd = ad as BannerAd;
            _isLoaded = true;
          });
        },
        onAdFailedToLoad: (ad, error) async {
          ad.dispose();
          debugPrint('BannerAd failed to load: $error');

          // First failure with personalized? Try non-personalized once.
          if (!nonPersonalized) {
            await _tryLoad(size, nonPersonalized: true);
            return;
          }

          // No fill again → schedule retry
          _scheduleRetry(size: size);
        },
      ),
    );

    try {
      await ad.load();
    } catch (_) {
      ad.dispose();
      _scheduleRetry(size: size);
    }
  }

  void _scheduleRetry({AdSize? size}) {
    if (!mounted) return;
    final delay =
        Duration(seconds: math.min(60, 2 << _retry)); // 2s,4s,8s,...≤60s
    _retry = math.min(_retry + 1, 5);

    Future.delayed(delay, () async {
      if (!mounted) return;
      final s = size ??
          await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
            MediaQuery.of(context).size.width.truncate(),
          );
      if (s == null) {
        _scheduleRetry();
        return;
      }
      await _tryLoad(s, nonPersonalized: true);
    });
  }

  Future<void> _disposeBanner() async {
    await _bannerAd?.dispose();
    _bannerAd = null;
  }

  @override
  void dispose() {
    _disposeBanner();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoaded && _bannerAd != null) {
      return SizedBox(
        width: _bannerAd!.size.width.toDouble(),
        height: _bannerAd!.size.height.toDouble(),
        child: AdWidget(ad: _bannerAd!),
      );
    }

    // Friendly placeholder while waiting / no fill
    return Container(
      height: 60,
      alignment: Alignment.center,
      color: Colors.green.shade50,
      child: const Text(
        "🐾 Discover nearby parks with InThePark!",
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
