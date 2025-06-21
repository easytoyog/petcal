import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:inthepark/services/firestore_service.dart';

class EditProfileScreen extends StatefulWidget {
  final TextEditingController firstNameController;
  final TextEditingController lastNameController;
  final TextEditingController phoneController;
  final TextEditingController emailController;
  final TextEditingController streetController;
  final TextEditingController cityController;
  final TextEditingController stateController;
  final TextEditingController countryController;
  final TextEditingController postalCodeController;

  EditProfileScreen({
    Key? key,
    required this.firstNameController,
    required this.lastNameController,
    required this.phoneController,
    required this.emailController,
    required this.streetController,
    required this.cityController,
    required this.stateController,
    required this.countryController,
    required this.postalCodeController,
  }) : super(key: key);

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Account"),
        content: const Text(
          "Are you sure you want to delete your account?\n\nDeleted accounts can't be restored.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              "Delete",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        await FirestoreService().markAccountInactive();
        await FirebaseAuth.instance.signOut();
        if (context.mounted) {
          Navigator.of(context).pushReplacementNamed('/login');
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to mark account as inactive: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF365A38),
      appBar: AppBar(
        backgroundColor: const Color(0xFF365A38),
        elevation: 0,
        title: const Text(
          "Edit Profile",
          style: TextStyle(
            color: Colors.tealAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.tealAccent),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Email field first, read-only
            TextField(
              controller: widget.emailController,
              enabled: false,
              style: const TextStyle(color: Colors.white70),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Email",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // First Name
            TextField(
              controller: widget.firstNameController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "First Name",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // Last Name
            TextField(
              controller: widget.lastNameController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Last Name",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // Phone
            TextField(
              controller: widget.phoneController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Phone",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // Street
            TextField(
              controller: widget.streetController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Street",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // City
            TextField(
              controller: widget.cityController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "City",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // State
            TextField(
              controller: widget.stateController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "State",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // Country
            TextField(
              controller: widget.countryController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Country",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 20),
            // Postal Code
            TextField(
              controller: widget.postalCodeController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.tealAccent,
              decoration: InputDecoration(
                labelText: "Postal Code",
                labelStyle: const TextStyle(color: Colors.tealAccent),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
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
              ),
            ),
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      // Save logic: only update first name, last name, and phone
                      final updatedFirstName = widget.firstNameController.text;
                      final updatedLastName = widget.lastNameController.text;
                      final updatedPhone = widget.phoneController.text;

                      Navigator.of(context).pop(true); // return success
                    },
                    child: const Text("Save", style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text(
                      "Cancel",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Center(
              child: SizedBox(
                width: 200,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.delete, color: Colors.white),
                  label: const Text("Delete Account"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14.0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text("Delete Account"),
                        content: const Text(
                          "Are you sure you want to delete your account?\n\nDeleted accounts can't be restored.",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text("Cancel"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text(
                              "Delete",
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await FirestoreService().markAccountInactive();
                      await FirebaseAuth.instance.signOut();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacementNamed('/login');
                      }
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
