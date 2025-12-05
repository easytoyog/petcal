import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class OwnerDetailsScreen extends StatefulWidget {
  const OwnerDetailsScreen({Key? key}) : super(key: key);

  @override
  State<OwnerDetailsScreen> createState() => _OwnerDetailsScreenState();
}

class _OwnerDetailsScreenState extends State<OwnerDetailsScreen> {
  final TextEditingController firstNameController = TextEditingController();
  final FocusNode firstNameFocusNode = FocusNode();
  final TextEditingController lastNameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();

  bool _isSaving = false;

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
    if (_isSaving) return; // prevent re-entry
    if (firstNameController.text.trim().isEmpty ||
        lastNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("First name and last name are required!")),
      );
      return;
    }

    setState(() => _isSaving = true);
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
          // NEW USER → initialize level/xp here
          tx.set(ref, {
            ...base,
            'level': 1,
            'xp': 0,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          // EXISTING USER → don't touch level/xp
          tx.update(ref, {
            ...base,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Owner details saved successfully!")),
      );

      // Avoid back-navigation to resubmit; replace the page.
      Navigator.pushReplacementNamed(context, '/petDetails');
    } catch (e) {
      debugPrint("Error saving owner details: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saving details: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
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
        backgroundColor: Colors.transparent, // so the gradient shows everywhere
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
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),

                // First name
                TextField(
                  controller: firstNameController,
                  focusNode: firstNameFocusNode,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent,
                  decoration: _inputDecoration(
                    hint: "First Name (Required)",
                    icon: Icons.person,
                  ),
                ),
                const SizedBox(height: 20),

                // Last name
                TextField(
                  controller: lastNameController,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.tealAccent,
                  decoration: _inputDecoration(
                    hint: "Last Name (Required)",
                    icon: Icons.account_circle,
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
                      backgroundColor:
                          _isSaving ? Colors.grey : Colors.tealAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isSaving ? null : saveOwnerDetails,
                    child: _isSaving
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
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
