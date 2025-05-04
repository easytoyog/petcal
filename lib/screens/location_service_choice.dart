import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class LocationServiceChoiceScreen extends StatefulWidget {
  const LocationServiceChoiceScreen({Key? key}) : super(key: key);

  @override
  _LocationServiceChoiceScreenState createState() =>
      _LocationServiceChoiceScreenState();
}

class _LocationServiceChoiceScreenState
    extends State<LocationServiceChoiceScreen> {
  int? selectedOption;

  Future<void> updateLocationType(int locationType) async {
    try {
      final String? uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        throw Exception("User not authenticated");
      }

      await FirebaseFirestore.instance.collection('owners').doc(uid).update({
        'locationType': locationType,
      });

      print("Location type updated successfully");
    } catch (e) {
      print("Error updating location type: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  void selectOption(int? value) {
    setState(() {
      selectedOption = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Location Service Choice"),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF567D46), Color(0xFF365A38)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 100, color: Colors.tealAccent),
              const SizedBox(height: 10),
              const Text(
                "Choose Your Location Settings",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 30),
              GestureDetector(
                onTap: () => selectOption(1),
                child: Card(
                  color: selectedOption == 1
                      ? Colors.teal.withOpacity(0.2)
                      : Colors.white.withOpacity(0.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Radio<int>(
                      value: 1,
                      groupValue: selectedOption,
                      onChanged: selectOption,
                      fillColor: WidgetStateProperty.all(Colors.tealAccent),
                    ),
                    title: const Text(
                      "Automatically show my location when I arrive at a park after 5 mins",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => selectOption(2),
                child: Card(
                  color: selectedOption == 2
                      ? Colors.teal.withOpacity(0.2)
                      : Colors.white.withOpacity(0.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Radio<int>(
                      value: 2,
                      groupValue: selectedOption,
                      onChanged: selectOption,
                      fillColor: WidgetStateProperty.all(Colors.tealAccent),
                    ),
                    title: const Text(
                      "Only show location if I open the app and will stay on for 30 mins",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => selectOption(3),
                child: Card(
                  color: selectedOption == 3
                      ? Colors.teal.withOpacity(0.2)
                      : Colors.white.withOpacity(0.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Radio<int>(
                      value: 3,
                      groupValue: selectedOption,
                      onChanged: selectOption,
                      fillColor: WidgetStateProperty.all(Colors.tealAccent),
                    ),
                    title: const Text(
                      "Only allow manual switch-on of location",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: MediaQuery.of(context).size.width / 2,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.tealAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    if (selectedOption == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Please select an option."),
                        ),
                      );
                      return;
                    }

                    await updateLocationType(selectedOption!);

                    Navigator.pushNamed(context, '/allsetup');
                  },
                  child: const Text(
                    "Complete Set Up",
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
