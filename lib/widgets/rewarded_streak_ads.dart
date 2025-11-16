import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kReleaseMode;
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
      // ✅ iOS app uses iOS rewarded; Android app uses Android rewarded
      return Platform.isIOS ? _liveIosRewarded : _liveAndroidRewarded;
    } else {
      // ✅ Use test IDs while developing
      return Platform.isIOS ? _testIosRewarded : _testAndroidRewarded;
    }
  }

  static Future<void> show({
    required void Function(RewardItem reward) onRewardEarned,
    void Function()? onDismissed,
    void Function(String message)? onFailedToShow, // pass error message up
  }) async {
    await RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              onDismissed?.call();
            },
            onAdFailedToShowFullScreenContent: (ad, err) {
              ad.dispose();
              onFailedToShow
                  ?.call('Failed to show: ${err.code} ${err.message}');
            },
          );
          ad.show(onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
            onRewardEarned(reward);
          });
        },
        onAdFailedToLoad: (err) {
          onFailedToShow?.call('Failed to load: ${err.code} ${err.message}');
        },
      ),
    );
  }
}
