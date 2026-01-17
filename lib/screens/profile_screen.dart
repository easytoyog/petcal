import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:inthepark/screens/map_tab.dart';
import 'package:inthepark/screens/parks_tab.dart';
import 'package:inthepark/screens/events_tab.dart';
import 'package:inthepark/screens/friends_tab.dart';
import 'package:inthepark/screens/profile_tab.dart';
import 'package:inthepark/screens/service_tab.dart';
import 'package:inthepark/widgets/%20xp_history_screen.dart';
import 'package:inthepark/widgets/level_system.dart';
import 'package:inthepark/widgets/streak_chip.dart';
import 'package:inthepark/widgets/xp_flyup_overlay.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  String? _selectedParkIdForEvents;

  final GlobalKey _xpBarKey = GlobalKey();

  List<Widget> get _pages => [
        ParksTab(
          onShowEvents: (parkId) {
            setState(() {
              _selectedParkIdForEvents = parkId;
              _selectedIndex = 2;
            });
          },
          onXpGained: () {
            XpFlyUpOverlay.show(
              context,
              xpBarKey: _xpBarKey,
              count: 8, // maybe a bit fewer than a walk
            );
          },
        ),
        MapTab(
          onShowEvents: (parkId) {
            setState(() {
              _selectedParkIdForEvents = parkId;
              _selectedIndex = 2;
            });
          },
          onXpGained: () {
            XpFlyUpOverlay.show(
              context,
              xpBarKey: _xpBarKey,
              count: 10,
            );
          },
        ),
        EventsTab(
          parkIdFilter: _selectedParkIdForEvents,
        ),
        const FriendsTab(),
        const ServiceTab(),
      ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      if (index != 2) {
        _selectedParkIdForEvents = null;
      }
    });
  }

  void _goToMapTab() {
    setState(() => _selectedIndex = 1); // index 1 = MapTab
  }

  void _openWalkHistory(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WalksListScreen(onGoToMapTab: _goToMapTab),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = ["Parks", "Explore", "Events", "Friends", "Promotions"];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF567D46),
        automaticallyImplyLeading: false,
        title: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('owners')
              .doc(FirebaseAuth.instance.currentUser!.uid)
              .collection('stats')
              .doc('level')
              .snapshots(),
          builder: (context, snap) {
            int level = 1;
            int currentXp = 0;
            int nextLevelXp = LevelSystem.xpForLevel(1);

            if (snap.hasData && snap.data!.exists) {
              final data = snap.data!;
              level = data.get('level') ?? 1;
              currentXp = data.get('currentXp') ?? 0;
              nextLevelXp =
                  data.get('nextLevelXp') ?? LevelSystem.xpForLevel(level);
            }

            final title = LevelSystem.titleForLevel(level);
            final progress = nextLevelXp > 0
                ? (currentXp / nextLevelXp).clamp(0.0, 1.0)
                : 0.0;

            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: StreakChip(
                    elevation: 0,
                    onTap: _goToMapTab, // 👈 only used when current <= 0
                  ),
                ),

                // 👇 Make the level area tappable
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const XpHistoryScreen(),
                        ),
                      );
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          "Lvl $level – $title",
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          key: _xpBarKey,
                          height: 8,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final maxWidth = constraints.maxWidth;
                              return Stack(
                                children: [
                                  Container(
                                    width: maxWidth,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.20),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeOutCubic,
                                    width: maxWidth * progress,
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFFFDD835),
                                          Color(0xFFFFB300),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                IconButton(
                  icon: const Icon(Icons.person, color: Colors.white),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(name: '/profile'),
                        builder: (_) => ProfileTab(
                          onGoToMapTab: () {
                            // 1) Pop everything above HomeScreen
                            Navigator.popUntil(
                                context, (route) => route.isFirst);

                            // 2) Switch bottom nav to the Map tab (index 1)
                            _goToMapTab();
                          },
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        backgroundColor: const Color(0xFF567D46),
        selectedItemColor: Colors.tealAccent,
        unselectedItemColor: Colors.white70,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.park), label: 'Parks'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Explore'),
          BottomNavigationBarItem(icon: Icon(Icons.event), label: 'Events'),
          BottomNavigationBarItem(icon: Icon(Icons.pets), label: 'Friends'),
          BottomNavigationBarItem(
              icon: Icon(Icons.storefront), label: 'Promotions'),
        ],
      ),
    );
  }
}
