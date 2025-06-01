import 'package:flutter/material.dart';
import 'package:inthepark/screens/map_tab.dart';
import 'package:inthepark/screens/parks_tab.dart';
import 'package:inthepark/screens/events_tab.dart';
import 'package:inthepark/screens/friends_tab.dart';
import 'package:inthepark/screens/profile_tab.dart';
import 'package:inthepark/screens/service_tab.dart';

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

  @override
  Widget build(BuildContext context) {
    final titles = ["Parks", "Explore", "Events", "Friends", "Services"];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_selectedIndex]),
        backgroundColor: const Color(0xFF567D46),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileTab()),
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
