import 'package:flutter/material.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SignupScreen extends StatelessWidget {
  final TextEditingController firstNameController = TextEditingController();
  final TextEditingController lastNameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController streetController = TextEditingController();
  final TextEditingController cityController = TextEditingController();
  final TextEditingController stateController = TextEditingController();
  final TextEditingController countryController = TextEditingController();
  final TextEditingController postalCodeController = TextEditingController();

  final FirestoreService firestoreService = FirestoreService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("First Time Sign-Up")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: firstNameController,
                decoration: const InputDecoration(
                  labelText: "First Name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: lastNameController,
                decoration: const InputDecoration(
                  labelText: "Last Name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: "Phone",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: streetController,
                decoration: const InputDecoration(
                  labelText: "Street Address",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: cityController,
                decoration: const InputDecoration(
                  labelText: "City",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: stateController,
                decoration: const InputDecoration(
                  labelText: "State/Province",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: countryController,
                decoration: const InputDecoration(
                  labelText: "Country",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16.0),
              TextField(
                controller: postalCodeController,
                decoration: const InputDecoration(
                  labelText: "Postal Code",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32.0),
              ElevatedButton(
                onPressed: () async {
                  try {
                    final owner = Owner(
                        uid: firestoreService.getCurrentUserId()!,
                        firstName: firstNameController.text.trim(),
                        lastName: lastNameController.text.trim(),
                        phone: phoneController.text.trim(),
                        email: FirebaseAuth.instance.currentUser!.email!,
                        pets: [],
                        address: Address(
                          street: streetController.text.trim(),
                          city: cityController.text.trim(),
                          state: stateController.text.trim(),
                          country: countryController.text.trim(),
                          postalCode: postalCodeController.text.trim(),
                        ),
                        locationType: 1);

                    await firestoreService.createOwner(owner);

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text("Owner created successfully!")),
                    );

                    Navigator.pushReplacementNamed(context, '/home');
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Error: $e")),
                    );
                  }
                },
                child: const Text("Submit"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
