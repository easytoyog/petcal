import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:inthepark/utils/image_upload_util.dart';

class AddPetScreen extends StatefulWidget {
  const AddPetScreen({Key? key}) : super(key: key);

  @override
  _AddPetScreenState createState() => _AddPetScreenState();
}

class _AddPetScreenState extends State<AddPetScreen> {
  /// Each pet is stored in [pets] as a Map:
  /// {
  ///   'name': String,
  ///   'photoUrl': String? (download URL),
  /// }
  List<Map<String, dynamic>> pets = [];

  /// Index of the pet chosen as "main pet"
  int? mainPetIndex;

  // Add this line:
  Set<int> uploadingIndexes = {};

  @override
  void initState() {
    super.initState();
    // Automatically add a default pet card
    addPetCard();
    mainPetIndex = 0; // Set the first pet as the main pet by default
  }

  /// Add a new pet card (with empty name + null photo)
  void addPetCard() {
    setState(() {
      pets.add({'name': '', 'photoUrl': null});
    });
  }

  /// Remove a pet card from the list
  void removePetCard(int index) {
    setState(() {
      pets.removeAt(index);
      // If we removed the main pet, reset or shift the mainPetIndex
      if (mainPetIndex == index) {
        mainPetIndex = null;
      } else if (mainPetIndex != null && mainPetIndex! > index) {
        mainPetIndex = mainPetIndex! - 1;
      }
    });
  }

  /// Prompt user to pick/upload an image for the [index]-th pet
  Future<void> pickAndUploadImage(int index) async {
    setState(() {
      uploadingIndexes.add(index);
    });

    final petIdForStorage = DateTime.now().millisecondsSinceEpoch.toString();

    final downloadUrl =
        await ImageUploadUtil.pickAndUploadPetPhoto(petIdForStorage);

    setState(() {
      uploadingIndexes.remove(index);
      if (downloadUrl != null) {
        pets[index]['photoUrl'] = downloadUrl;
      }
    });
  }

  /// Save pets to Firestore
  Future<void> savePets() async {
  if (pets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Please add at least one pet.")),
    );
    return;
  }
  mainPetIndex ??= 0;

  try {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final col = FirebaseFirestore.instance.collection('pets');

    for (int i = 0; i < pets.length; i++) {
      final pet = pets[i];
      await col.add({
        'ownerId' : uid,
        'name'    : (pet['name'] as String?)?.trim() ?? '',
        'photoUrl': pet['photoUrl'],         // may be null or string
        'isMain'  : (i == mainPetIndex),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Pets saved successfully!")),
    );
    Navigator.pushNamed(context, '/allsetup');
  } catch (e) {
    debugPrint("Error saving pets: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Error: $e")),
    );
  }
}


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Add Pets"),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: SafeArea( // <-- Wrap with SafeArea
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF567D46), Color(0xFF365A38)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  children: [
                    const SizedBox(height: 20),
                    const Icon(Icons.pets, size: 100, color: Colors.tealAccent),
                    const SizedBox(height: 10),
                    const Text(
                      "Add Your Pets!",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    ListView.builder(
                      itemCount: pets.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemBuilder: (context, index) {
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 10.0),
                          color: Colors.white.withOpacity(0.1),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    // Pet Name field
                                    Expanded(
                                      child: TextField(
                                        onChanged: (value) {
                                          pets[index]['name'] = value;
                                        },
                                        style:
                                            const TextStyle(color: Colors.white),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor:
                                              Colors.white.withOpacity(0.1),
                                          hintText: "Pet Name",
                                          hintStyle: const TextStyle(
                                              color: Colors.white70),
                                          prefixIcon: const Icon(Icons.pets,
                                              color: Colors.white),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide.none,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    // Pet Photo area
                                    GestureDetector(
                                      onTap: () => pickAndUploadImage(index),
                                      child: CircleAvatar(
                                        radius: 40,
                                        backgroundColor:
                                            Colors.white.withOpacity(0.1),
                                        backgroundImage: (pets[index]['photoUrl'] != null && !uploadingIndexes.contains(index))
                                            ? NetworkImage(pets[index]['photoUrl'])
                                            : null,
                                        child: uploadingIndexes.contains(index)
                                            ? const CircularProgressIndicator(
                                                valueColor: AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                                              )
                                            : (pets[index]['photoUrl'] == null
                                                ? const Icon(Icons.add_a_photo, color: Colors.white)
                                                : null),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                // Main Pet radio + delete
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Radio<int>(
                                          value: index,
                                          groupValue: mainPetIndex,
                                          onChanged: (value) {
                                            setState(() {
                                              mainPetIndex = value;
                                            });
                                          },
                                          fillColor: WidgetStateProperty.all(
                                              Colors.tealAccent),
                                        ),
                                        const Text(
                                          "Set as Main Pet",
                                          style: TextStyle(color: Colors.white70),
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.red),
                                      onPressed: () => removePetCard(index),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: addPetCard,
                      child: const Text("Add Another Pet"),
                    ),
                  ],
                ),
              ),
              // Save Pets
              Padding(
                padding: EdgeInsets.only(
                  left: 24.0,
                  right: 24.0,
                  bottom: MediaQuery.of(context).viewPadding.bottom + 24.0, // <-- Add dynamic bottom padding
                  top: 0,
                ),
                child: SizedBox(
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
                    onPressed: savePets,
                    child: const Text("Save Pets", style: TextStyle(fontSize: 18)),
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
