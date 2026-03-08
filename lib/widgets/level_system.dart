import 'package:cloud_firestore/cloud_firestore.dart';

class LevelSystem {
  static int xpForLevel(int level) {
    return 100 + (level * level * 50);
  }

  /// Simple yyyy-MM-dd key in *local* time.
  static String _todayKey() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Call this from ANY place that awards daily park check-in XP.
  static Future<Map<String, dynamic>> awardDailyParkCheckInXp(String uid) {
    // 20 XP is just an example – keep whatever you’re using in ParkTab.
    return addXp(
      uid,
      20,
      reason: 'Daily park check-in',
    );
  }

  /// Adds XP and returns:
  /// {
  ///   'level': int,
  ///   'leveledUp': bool,
  ///   'skipped': bool,   // true if daily-limited XP was skipped
  /// }
  ///
  /// When [reason] == 'Daily park check-in', XP will only be granted once per day.
  static Future<Map<String, dynamic>> addXp(
    String uid,
    int amount, {
    String reason = 'XP gain',
  }) async {
    final db = FirebaseFirestore.instance;
    final ownerRef = db.collection('owners').doc(uid);
    final levelRef = ownerRef.collection('stats').doc('level');

    final bool isDailyCheckin = reason == 'Daily park check-in';
    final String? dailyKey = isDailyCheckin ? _todayKey() : null;
    final DocumentReference<Map<String, dynamic>>? dailyRef =
        dailyKey != null ? ownerRef.collection('xpDaily').doc(dailyKey) : null;

    final logRef = ownerRef.collection('xpLogs').doc(); // auto id

    return db.runTransaction((tx) async {
      // Read current level state
      final levelSnap = await tx.get(levelRef);

      int level = 1;
      int currentXp = 0;
      int nextLevelXp = xpForLevel(1);

      if (levelSnap.exists) {
        final d = levelSnap.data()!;
        level = d['level'] ?? 1;
        currentXp = d['currentXp'] ?? 0;
        nextLevelXp = d['nextLevelXp'] ?? xpForLevel(level);
      }

      // For daily-limited XP, check if we've already given it today.
      if (dailyRef != null) {
        final dailySnap = await tx.get(dailyRef);
        if (dailySnap.exists) {
          // Already granted today's check-in XP → no XP change, no log.
          return {
            'level': level,
            'leveledUp': false,
            'skipped': true,
          };
        }
      }

      // Apply XP
      currentXp += amount;
      bool leveledUp = false;

      while (currentXp >= nextLevelXp) {
        currentXp -= nextLevelXp;
        level++;
        nextLevelXp = xpForLevel(level);
        leveledUp = true;
      }

      // Update level doc
      tx.set(
        levelRef,
        {
          'level': level,
          'currentXp': currentXp,
          'nextLevelXp': nextLevelXp,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      // Write XP log entry
      tx.set(logRef, {
        'amount': amount,
        'reason': reason,
        'createdAt': FieldValue.serverTimestamp(),
        'levelAfter': level,
      });

      // Mark daily check-in as used
      if (dailyRef != null) {
        tx.set(dailyRef, {
          'type': reason,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      return {
        'level': level,
        'leveledUp': leveledUp,
        'skipped': false,
      };
    });
  }

  static String titleForLevel(int level) {
    const titles = [
      "Novice Dog Owner", // 1
      "Pup Pal", // 2
      "Daily Walker", // 3
      "Park Explorer", // 4
      "Trail Treader", // 5
      "Sniff Scout", // 6
      "Loyal Walker", // 7
      "Adventure Buddy", // 8
      "Pawsitive Partner", // 9
      "Pup Champion", // 10
      "Trail Master", // 11
      "Pack Leader", // 12
      "Adventure Pro", // 13
      "Elite Walker", // 14
      "Canine Companion", // 15
      "Wag Warrior", // 16
      "Sniff Specialist", // 17
      "Alpha Adventurer", // 18
      "Legendary Walker", // 19
      "Dog Guardian", // 20
      "Master Tracker", // 21
      "Pawkour Pro", // 22
      "Tail Blazer", // 23
      "Trail Titan", // 24
      "Fetch Legend", // 25
      "Park Phantom", // 26
      "Boundless Pup", // 27
      "Route Runner", // 28
      "Terrain Tamer", // 29
      "Wanderlust Warrior", // 30
      "Peak Prowler", // 31
      "Stride Striker", // 32
      "Distance Dominator", // 33
      "Venture Virtuoso", // 34
      "Pathfinder Master", // 35
      "Quest Crusader", // 36
      "Marathon Mutt", // 37
      "Expedition Expert", // 38
      "Odyssey Overlord", // 39
      "Nomadic Noble", // 40
      "Pioneer Patriarch", // 41
      "Sentinel Supreme", // 42
      "Ethereal Explorer", // 43
      "Cosmic Canine", // 44
      "Celestial Champion", // 45
      "Mythic Mountain Lord", // 46
      "Divine Drifter", // 47
      "Eternal Expeditioner", // 48
      "Immortal Adventurer", // 49
      "Transcendent Tracker", // 50
      "Apex Alpha", // 51
      "Primordial Pathfinder", // 52
      "Sovereign Strider", // 53
      "Supremacy Seeker", // 54
      "Ultimate Wanderer", // 55
      "Legendary Luminary", // 56
      "Infinite Adventurer", // 57
      "Dimensional Drifter", // 58
      "Paragon of Progress", // 59
      "Supreme Sovereign - The Ultimate Pup Legend", // 60
    ];

    if (level <= titles.length) return titles[level - 1];
    return "Supreme Sovereign";
  }
}
