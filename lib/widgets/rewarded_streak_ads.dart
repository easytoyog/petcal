import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode, debugPrint;
import 'package:google_mobile_ads/google_mobile_ads.dart';

class RewardedStreakAds {
  // --- Live AdMob IDs (✅ your real units) ---
  static const _liveIosAppId = 'ca-app-pub-3773871623541431~4689160792';
  static const _liveAndroidAppId = 'ca-app-pub-3773871623541431~8626595595';
  static const _liveIosRewarded = 'ca-app-pub-3773871623541431/6279693265';
  static const _liveAndroidRewarded = 'ca-app-pub-3773871623541431/7525326329';

  // --- Google test units (safe for dev/debug) ---
  static const _testIosRewarded = 'ca-app-pub-3940256099942544/1712485313';
  static const _testAndroidRewarded = 'ca-app-pub-3940256099942544/5224354917';

  static String get _adUnitId {
    if (kReleaseMode) {
      return Platform.isIOS ? _liveIosRewarded : _liveAndroidRewarded;
    } else {
      return Platform.isIOS ? _testIosRewarded : _testAndroidRewarded;
    }
  }

  /// Hard guarantee:
  /// - Calls exactly ONE of the terminal callbacks:
  ///   - onDismissed OR onFailedToShow
  /// - Never hangs the caller (watchdog timeout)
  static Future<void> show({
    required void Function(RewardItem reward) onRewardEarned,
    void Function()? onDismissed,
    void Function(String message)? onFailedToShow,
    void Function()? onAdShown,
  }) async {
    // --- Terminal guard (exactly-once) ---
    var terminalFired = false;

    void fireDismissed() {
      if (terminalFired) return;
      terminalFired = true;
      onDismissed?.call();
    }

    void fireFailed(String msg) {
      if (terminalFired) return;
      terminalFired = true;
      onFailedToShow?.call(msg);
    }

    // --- Watchdog: if SDK never calls dismissed/failed, we still end. ---
    // Adjust timeout as you like.
    Timer? watchdog;
    watchdog = Timer(const Duration(seconds: 6000), () {
      fireFailed(
          'Rewarded ad timed out (no terminal callback). Please try again.');
    });

    RewardedAd? ad;

    try {
      // RewardedAd.load uses callbacks, so wrap it in a Completer
      final loadCompleter = Completer<void>();

      RewardedAd.load(
        adUnitId: _adUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (loadedAd) {
            ad = loadedAd;

            // Attach callbacks BEFORE show()
            loadedAd.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (ad) {
                onAdShown?.call();
              },
              onAdDismissedFullScreenContent: (ad) {
                ad.dispose();
                watchdog?.cancel();
                fireDismissed();
              },
              onAdFailedToShowFullScreenContent: (ad, err) {
                ad.dispose();
                watchdog?.cancel();
                fireFailed('Failed to show: ${err.code} ${err.message}');
              },
              // Optional: treat "impression" as additional proof it displayed
              onAdImpression: (ad) {},
            );

            // Mark load complete
            if (!loadCompleter.isCompleted) loadCompleter.complete();

            // Now show it (can throw)
            try {
              loadedAd.show(
                onUserEarnedReward: (AdWithoutView _, RewardItem reward) {
                  onRewardEarned(reward);
                },
              );
            } catch (e) {
              // If show throws, we MUST end terminally
              loadedAd.dispose();
              watchdog?.cancel();
              fireFailed('Exception while showing ad: $e');
            }
          },
          onAdFailedToLoad: (err) {
            watchdog?.cancel();
            fireFailed('Failed to load: ${err.code} ${err.message}');
            if (!loadCompleter.isCompleted) loadCompleter.complete();
          },
        ),
      );

      // Wait for load callback to happen (success or fail)
      await loadCompleter.future;
    } catch (e) {
      // Covers any synchronous exceptions around load()
      watchdog?.cancel();
      try {
        ad?.dispose();
      } catch (_) {}
      fireFailed('Rewarded ad error: $e');
    } finally {
      // If we already ended, cancel watchdog.
      if (terminalFired) {
        watchdog?.cancel();
      }
    }
  }
}
