import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Lightweight model for the streak doc.
class WalkStreak {
  final int current;
  final int longest;
  const WalkStreak({required this.current, required this.longest});

  static WalkStreak fromSnap(DocumentSnapshot snap) {
    if (!snap.exists) return const WalkStreak(current: 0, longest: 0);
    final data = snap.data() as Map<String, dynamic>? ?? const {};
    return WalkStreak(
      current: (data['current'] ?? 0) as int,
      longest: (data['longest'] ?? 0) as int,
    );
  }
}

/// Reusable chip that listens to owners/{uid}/stats/walkStreak in Firestore
/// and renders a compact “Streak / Best” pill.
///
/// - Provide [userId] or it will use the current Firebase user.
/// - Customize look with [background], [elevation], [padding], [textStyle].
/// - Use [onTap] to open a custom dialog or screen (defaults to a simple info dialog).
class StreakChip extends StatelessWidget {
  final String? userId;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? background;
  final double elevation;
  final TextStyle? textStyle;
  final bool showBestBadge;
  final bool useRootNavigator;

  const StreakChip({
    Key? key,
    this.userId,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.background,
    this.elevation = 0,
    this.textStyle,
    this.showBestBadge = true,
    this.useRootNavigator = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    final baseTextStyle =
        textStyle ?? const TextStyle(fontWeight: FontWeight.w800, fontSize: 13);

    final Color shellBg = background ??
        // Subtle glass on iOS feel; solid on Android-like look
        Colors.white.withOpacity(0.90);

    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: Colors.orange.shade200, width: 1.0),
    );

    return Material(
      color: shellBg,
      elevation: elevation,
      shape: border,
      shadowColor: Colors.black12,
      child: StreamBuilder<DocumentSnapshot>(
        stream: docRef.snapshots(),
        builder: (context, snap) {
          final streak = (snap.hasData)
              ? WalkStreak.fromSnap(snap.data!)
              : const WalkStreak(current: 0, longest: 0);

          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap ?? () => _defaultDialog(context),
            child: Padding(
              padding: padding,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department,
                      size: 18, color: Colors.orange.shade700),
                  const SizedBox(width: 6),
                  Text('${streak.current}', style: baseTextStyle),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _defaultDialog(BuildContext context) {
    showDialog(
      context: context,
      useRootNavigator: useRootNavigator,
      builder: (ctx) => AlertDialog(
        title: const Text('Daily Walk Streak'),
        content: const Text(
          'Complete at least one walk per day to keep the streak alive.\n\n'
          'Tip: You can add a rewarded-ad “revive” if a day was missed.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(ctx, rootNavigator: useRootNavigator).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Convenience wrapper to place the chip as an overlay at top-left of a page/tab.
/// Add this inside a Stack() without needing to re-implement SafeArea/padding.
class StreakChipOverlay extends StatelessWidget {
  final String? userId;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  final bool showBestBadge;
  final bool useRootNavigator;

  const StreakChipOverlay({
    Key? key,
    this.userId,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(12, 12, 0, 0),
    this.showBestBadge = true,
    this.useRootNavigator = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Try to look nice on both platforms with a subtle shadow
    return SafeArea(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: margin,
          child: StreakChip(
            userId: userId,
            onTap: onTap,
            elevation: 2,
            showBestBadge: showBestBadge,
            useRootNavigator: useRootNavigator,
            // if you want a glass look on iOS, you can pass a translucent bg here
          ),
        ),
      ),
    );
  }
}
