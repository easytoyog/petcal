import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:inthepark/screens/profile_tab.dart'; // for WalksListScreen

class StreakChip extends StatelessWidget {
  final double elevation;
  final Color? background;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  const StreakChip({
    super.key,
    this.elevation = 0,
    this.background,
    this.textStyle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const SizedBox.shrink();
    }

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    return StreamBuilder<DocumentSnapshot>(
      stream: docRef.snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return _buildChip(
            context,
            current: 0,
            longest: 0,
            reviveEligible: false,
            prevBeforeLoss: null,
          );
        }

        final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};

        int _readInt(dynamic v) {
          if (v is int) return v;
          return int.tryParse('$v') ?? 0;
        }

        final int current = _readInt(data['current']);
        final int longest = _readInt(data['longest']);
        final int? prevBeforeLoss = data['prevBeforeLoss'] != null
            ? _readInt(data['prevBeforeLoss'])
            : null;

        final String? lastDateStr = (data['lastDate'] as String?)?.trim();

        // ---- DATE-ONLY REVIVE LOGIC ----
        DateTime? _parseDayKey(String s) {
          final parts = s.split('-');
          if (parts.length != 3) return null;
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[2]);
          if (y == null || m == null || d == null) return null;
          return DateTime(y, m, d); // local day
        }

        bool reviveEligible = false;
        if (lastDateStr != null && lastDateStr.isNotEmpty) {
          final lastDay = _parseDayKey(lastDateStr);
          if (lastDay != null) {
            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            final diffDays = today.difference(lastDay).inDays;

            // ✅ PRIORITY: as long as last day is > 2 days before today → blue
            // e.g. lastDate = 13th, today = 15th → diffDays = 2 → blue
            reviveEligible = diffDays >= 2 && current > 0;
          }
        }

        return _buildChip(
          context,
          current: current,
          longest: longest,
          reviveEligible: reviveEligible,
          prevBeforeLoss: prevBeforeLoss,
        );
      },
    );
  }

  Widget _buildChip(
    BuildContext context, {
    required int current,
    required int longest,
    required bool reviveEligible,
    required int? prevBeforeLoss,
  }) {
    final baseTextStyle = textStyle ??
        const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 12,
          color: Colors.black87,
        );

    final bool danger = reviveEligible;

    // 🔵 Blue attention state when revive-eligible
    final Color chipBg = danger
        ? const Color(0xFF005BFF)
        : (background ?? Colors.white.withOpacity(0.95));

    final Color chipBorder =
        danger ? const Color(0xFF9EC9FF) : Colors.black.withOpacity(0.06);

    final Color chipTextColor =
        danger ? Colors.white : (baseTextStyle.color ?? Colors.black87);

    // Label: normal vs revive mode
    final String streakLabel;
    if (!danger && current <= 0) {
      streakLabel = 'Start a streak';
    } else if (danger) {
      final shown = (prevBeforeLoss ?? current);
      streakLabel = '🔥 $shown!';
    } else {
      streakLabel = '🔥 $current';
    }

    final String tooltip;
    if (!danger && current <= 0) {
      tooltip = "Start a walk to begin your streak";
    } else if (danger) {
      final lost = prevBeforeLoss ?? current;
      tooltip = "You missed some days – tap to revive your $lost-day streak.";
    } else {
      tooltip =
          "Current walk streak: $current day${current == 1 ? '' : 's'} (Best: $longest)";
    }

    // 👇 Only allow taps in the "Start a streak" state
    final bool hasStreak = current > 0;

    VoidCallback? effectiveOnTap;
    if (hasStreak) {
      effectiveOnTap = () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const WalksListScreen(),
          ),
        );
      };
    } else {
      // "Start a streak" state, delegate to parent (e.g. _goToMapTab)
      effectiveOnTap = onTap;
    }

    return Material(
      color: Colors.transparent,
      elevation: elevation,
      child: InkWell(
        onTap: effectiveOnTap,
        borderRadius: BorderRadius.circular(30),
        child: Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: chipBg,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: chipBorder, width: danger ? 1.6 : 1),
              boxShadow: danger
                  ? [
                      BoxShadow(
                        color: const Color(0xFF4FACFE).withOpacity(0.6),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  streakLabel,
                  style: baseTextStyle.copyWith(color: chipTextColor),
                ),
                if (longest > 0 && !danger && current > 0) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: Colors.orange.shade700,
                  ),
                ],
                if (danger) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.priority_high_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
