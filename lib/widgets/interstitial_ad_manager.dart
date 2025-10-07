// lib/ads/interstitial_ad_manager.dart
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:google_mobile_ads/google_mobile_ads.dart';

typedef VoidCallback = void Function();
typedef ConsentReady = Future<bool>
    Function(); // return true when UMP/consent is done

class InterstitialAdManager {
  InterstitialAd? _ad;
  bool _isLoading = false;

  // Cooldown between shows
  final int cooldownSeconds;
  DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);

  // Load retry policy
  final int maxLoadAttempts;
  int _loadAttempts = 0;

  // Optional: wait for UMP/consent + SDK init before loading ads
  final ConsentReady? waitForConsent;

  InterstitialAdManager({
    this.cooldownSeconds = 60,
    this.maxLoadAttempts = 5,
    this.waitForConsent,
    String? androidUnitRelease,
    String? iosUnitRelease,
  })  : _androidUnitRelease =
            androidUnitRelease ?? 'ca-app-pub-3773871623541431/7192936872',
        _iosUnitRelease =
            iosUnitRelease ?? 'ca-app-pub-3773871623541431/8952757010';

  final String _androidUnitRelease;
  final String _iosUnitRelease;

  // ———————————————————————————————————————————
  // Public API
  // ———————————————————————————————————————————

  bool get isAvailable => _ad != null;

  /// Preload an ad if none is available.
  void preload() {
    if (_ad != null || _isLoading) return;
    _isLoading = true;
    _ensureInitAndConsent().then((_) {
      _tryLoad(nonPersonalized: false); // try personalized first
    }).catchError((_) {
      _isLoading = false;
      _scheduleRetry();
    });
  }

  /// Try to show the interstitial.
  Future<void> show({
    VoidCallback? onShown,
    VoidCallback? onClosed,
    VoidCallback? onUnavailable,
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastShown).inSeconds < cooldownSeconds) {
      onUnavailable?.call();
      return;
    }

    // If no ad ready, kick a load and bail
    if (_ad == null) {
      preload();
      onUnavailable?.call();
      return;
    }

    try {
      _wireFullScreenCallbacks(_ad!, onClosed);
      _ad!.show();
      _lastShown = now;
      onShown?.call();
      _ad = null; // consumed by show; next one will be preloaded in callbacks
    } catch (_) {
      _ad?.dispose();
      _ad = null;
      preload();
      onUnavailable?.call();
    }
  }

  void dispose() {
    _ad?.dispose();
    _ad = null;
  }

  // ———————————————————————————————————————————
  // Internals
  // ———————————————————————————————————————————

  static bool _sdkInitialized = false;
  bool _consentCheckedThisSession = false;

  String get _adUnitId {
    if (!kReleaseMode) {
      return Platform.isAndroid
          ? 'ca-app-pub-3940256099942544/1033173712' // SAMPLE Android interstitial
          : 'ca-app-pub-3940256099942544/4411468910'; // SAMPLE iOS interstitial
    }
    return Platform.isAndroid ? _androidUnitRelease : _iosUnitRelease;
  }

  Future<void> _ensureInitAndConsent() async {
    if (!_consentCheckedThisSession && waitForConsent != null) {
      try {
        await waitForConsent!.call();
      } catch (_) {
        // even if consent “fails”, we still try initializing ads
      }
      _consentCheckedThisSession = true;
    }
    if (!_sdkInitialized) {
      try {
        await MobileAds.instance.initialize();
        _sdkInitialized = true;
      } catch (_) {
        rethrow;
      }
    }
  }

  AdRequest _request({required bool nonPersonalized}) => AdRequest(
        nonPersonalizedAds: nonPersonalized,
        // extras: {'npa': nonPersonalized ? '1' : '0'}, // alternative forcing
        keywords: const ['dogs', 'parks', 'pets'],
        contentUrl: 'https://inthepark.dog',
      );

  void _tryLoad({required bool nonPersonalized}) {
    InterstitialAd.load(
      adUnitId: _adUnitId,
      request: _request(nonPersonalized: nonPersonalized),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _isLoading = false;
          _loadAttempts = 0;
          _ad = ad;
          // Don’t set fullScreenContentCallback yet; set it right before show()
        },
        onAdFailedToLoad: (error) async {
          _ad = null;
          _isLoading = false;

          // If personalized failed first, try a single non-personalized load immediately.
          if (!nonPersonalized) {
            _isLoading = true;
            _tryLoad(nonPersonalized: true);
            return;
          }
          _scheduleRetry();
        },
      ),
    );
  }

  void _scheduleRetry() {
    _loadAttempts++;
    if (_loadAttempts > maxLoadAttempts) return;
    final secs = math.min(60, 2 << (_loadAttempts - 1)); // 1,2,4,8,16,32,60
    Future.delayed(Duration(seconds: secs), () {
      if (_ad == null && !_isLoading) {
        _isLoading = true;
        _tryLoad(nonPersonalized: true);
      }
    });
  }

  void _wireFullScreenCallbacks(InterstitialAd ad, VoidCallback? onClosed) {
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        // optional: analytics
      },
      onAdImpression: (ad) {
        // optional: analytics
      },
      onAdClicked: (ad) {
        // optional: analytics
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _ad = null;
        onClosed = null; // don’t call onClosed on failure
        _scheduleRetry();
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _ad = null;
        // Preload next after close to keep inventory warm
        preload();
        onClosed?.call();
      },
    );
  }
}
