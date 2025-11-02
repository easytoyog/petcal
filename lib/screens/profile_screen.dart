import 'package:flutter/material.dart';
import 'package:inthepark/screens/map_tab.dart';
import 'package:inthepark/screens/parks_tab.dart';
import 'package:inthepark/screens/events_tab.dart';
import 'package:inthepark/screens/friends_tab.dart';
import 'package:inthepark/screens/profile_tab.dart';
import 'package:inthepark/screens/service_tab.dart';
import 'package:inthepark/widgets/streak_chip.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  String? _selectedParkIdForEvents;

  List<Widget> get _pages => [
        ParksTab(
          onShowEvents: (parkId) {
            setState(() {
              _selectedParkIdForEvents = parkId;
              _selectedIndex = 2;
            });
          },
        ),
        MapTab(
          onShowEvents: (parkId) {
            setState(() {
              _selectedParkIdForEvents = parkId;
              _selectedIndex = 2;
            });
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
    setState(() => _selectedIndex = 1); // assuming index 1 is MapTab
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
    final titles = ["Parks", "Explore", "Events", "Friends", "Services"];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF567D46),
        automaticallyImplyLeading: false,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left: Streak chip
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: StreakChip(
                elevation: 0,
                background: Colors.white.withOpacity(0.95),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
                onTap: () => _openWalkHistory(context),
              ),
            ),

            // Center: Title text (expanded to truly center)
            Expanded(
              child: Center(
                child: Text(
                  titles[_selectedIndex],
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 24,
                    color: Colors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

            // Right: same width as left padding + icon size to balance visually
            const SizedBox(width: 18),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  settings: const RouteSettings(name: '/profile'),
                  builder: (_) => const ProfileTab(),
                ),
              );
            },
          ),
        ],
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
              icon: Icon(Icons.storefront), label: 'Services'),
        ],
      ),
    );
  }
}
