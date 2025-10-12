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

  @override
  void initState() {
    super.initState();
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
      final user = FirebaseAuth.instance.currentUser!;
      final uid = user.uid;
      final ref = FirebaseFirestore.instance.collection('owners').doc(uid);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);

        // address intentionally empty
        final base = {
          'email': user.email ?? '',
          'firstName': firstNameController.text.trim(),
          'lastName': lastNameController.text.trim(),
          'phone': phoneController.text.trim(),
          'address': {
            'line1': '',
            'city': '',
            'state': '',
            'postalCode': '',
            'country': '',
          },
          'active': true,
        };

        if (!snap.exists) {
          tx.set(ref, {
            ...base,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          tx.update(ref, {
            ...base,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Owner details saved successfully!")),
      );
      Navigator.pushNamed(context, '/petDetails');
    } catch (e) {
      debugPrint("Error saving owner details: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error saving details: $e")),
      );
    }
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
  }) {
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
        borderSide: const BorderSide(color: Colors.tealAccent, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Draw gradient behind the entire screen (fixes white area at bottom)
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF567D46), Color(0xFF365A38)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors
            .transparent, // important so the gradient shows everywhere (no white gap)
        appBar: AppBar(
          title: const Text("Owner Details"),
          backgroundColor: const Color(0xFF567D46),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24.0, 0, 24.0, 40.0),
            child: Column(
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

                // First name (icon: person)
                TextField(
                  controller: firstNameController,
                  focusNode: firstNameFocusNode,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent,
                  decoration: _inputDecoration(
                    hint: "First Name (Required)",
                    icon: Icons.person, // nicer for first name
                  ),
                ),
                const SizedBox(height: 20),

                // Last name (auto-capitalize words, icon: badge)
                TextField(
                  controller: lastNameController,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization
                      .words, // auto-capitalize last name as you type
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent,
                  decoration: _inputDecoration(
                    hint: "Last Name (Required)",
                    icon: Icons.account_circle, // clearer for surname/identity
                  ),
                ),
                const SizedBox(height: 20),

                // Phone
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent,
                  decoration: _inputDecoration(
                    hint: "Phone Number (Optional)",
                    icon: Icons.phone,
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
                    child: const Text(
                      "Next Add Pets",
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
