import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class OwnerDetailsScreen extends StatefulWidget {
  const OwnerDetailsScreen({Key? key}) : super(key: key);

  @override
  _OwnerDetailsScreenState createState() => _OwnerDetailsScreenState();
}

class _OwnerDetailsScreenState extends State<OwnerDetailsScreen> {
  final TextEditingController firstNameController = TextEditingController();
  final FocusNode firstNameFocusNode = FocusNode();
  final TextEditingController lastNameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController addressLine1Controller = TextEditingController();
  final TextEditingController cityController = TextEditingController();
  final TextEditingController stateController = TextEditingController();
  final TextEditingController postalCodeController = TextEditingController();
  final TextEditingController countryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Auto-focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      firstNameFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    firstNameController.dispose();
    firstNameFocusNode.dispose();
    lastNameController.dispose();
    phoneController.dispose();
    addressLine1Controller.dispose();
    cityController.dispose();
    stateController.dispose();
    postalCodeController.dispose();
    countryController.dispose();
    super.dispose();
  }

  Future<void> saveOwnerDetails() async {
    if (firstNameController.text.trim().isEmpty ||
        lastNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("First name and last name are required!")),
      );
      return;
    }

    try {
      final String uid = FirebaseAuth.instance.currentUser!.uid;

      await FirebaseFirestore.instance.collection('owners').doc(uid).set({
        'email': FirebaseAuth.instance.currentUser!.email, // <-- Add this line
        'firstName': firstNameController.text.trim(),
        'lastName': lastNameController.text.trim(),
        'phone': phoneController.text.trim(),
        'address': {
          'line1': addressLine1Controller.text.trim(),
          'city': cityController.text.trim(),
          'state': stateController.text.trim(),
          'postalCode': postalCodeController.text.trim(),
          'country': countryController.text.trim(),
        },
        'active': true, // <-- Add this line
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Owner details saved successfully!")),
      );

      Navigator.pushNamed(context, '/petDetails');
    } catch (e) {
      print("Error saving owner details: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error saving details: $e")),
      );
    }
  }

  InputDecoration _inputDecoration(
      {required String hint, required IconData icon}) {
    return InputDecoration(
      filled: true,
      fillColor: Colors.white.withOpacity(0.1),
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icon, color: Colors.white),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Colors.tealAccent,
          width: 2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Owner Details"),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.person, size: 100, color: Colors.tealAccent),
              const SizedBox(height: 10),
              const Text(
                "First tell us about yourself!",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 30),
              TextField(
                controller: firstNameController,
                focusNode: firstNameFocusNode,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "First Name (Required)",
                  icon: Icons.account_circle,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: lastNameController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "Last Name (Required)",
                  icon: Icons.account_circle_outlined,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "Phone Number (Optional)",
                  icon: Icons.phone,
                ),
              ),
              const SizedBox(height: 20),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Address (Optional)",
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Don't worry, your address will not be visible to other users.",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: addressLine1Controller,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "Address Line 1",
                  icon: Icons.home,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: cityController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "City",
                  icon: Icons.location_city,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: stateController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "State/Province",
                  icon: Icons.map,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: postalCodeController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                ],
                decoration: _inputDecoration(
                  hint: "Postal Code",
                  icon: Icons.local_post_office,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: countryController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.tealAccent,
                decoration: _inputDecoration(
                  hint: "Country",
                  icon: Icons.public,
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
                  onPressed: saveOwnerDetails,
                  child: const Text("Next Add Pets",
                      style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }
}
