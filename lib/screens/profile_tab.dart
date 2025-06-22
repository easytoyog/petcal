import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:inthepark/models/pet_model.dart';
import 'package:inthepark/utils/image_upload_util.dart';
import 'package:inthepark/screens/owner_detail_screen.dart';
import 'package:inthepark/screens/edit_profile_screen.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({Key? key}) : super(key: key);

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final _firestoreService = FirestoreService();

  // Add the missing controllers
  late final TextEditingController firstNameController;
  late final TextEditingController lastNameController;
  late final TextEditingController phoneController;
  late final TextEditingController emailController;
  late final TextEditingController streetController;
  late final TextEditingController cityController;
  late final TextEditingController stateController;
  late final TextEditingController countryController;
  late final TextEditingController postalCodeController;

  bool _isLoading = true;
  Owner? _owner;
  List<Pet> _pets = [];

  @override
  void initState() {
    super.initState();
    _loadOwnerAndPets();
  }

  @override
  void dispose() {
    // Don't forget to dispose controllers
    firstNameController.dispose();
    lastNameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    streetController.dispose();
    cityController.dispose();
    stateController.dispose();
    countryController.dispose();
    postalCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadOwnerAndPets() async {
    setState(() => _isLoading = true);
    try {
      final owner = await _firestoreService.getOwner();
      if (owner == null) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => OwnerDetailsScreen()),
          );
        }
        return;
      }
      final pets = await _firestoreService.getPetsForOwner(owner.uid);
      setState(() {
        _owner = owner;
        _pets = pets;
        // Initialize controllers with current owner data
        firstNameController =
            TextEditingController(text: _owner?.firstName ?? '');
        lastNameController =
            TextEditingController(text: _owner?.lastName ?? '');
        phoneController = TextEditingController(text: _owner?.phone ?? '');
        emailController = TextEditingController(text: _owner?.email ?? '');
        streetController =
            TextEditingController(text: _owner?.address.street ?? '');
        cityController =
            TextEditingController(text: _owner?.address.city ?? '');
        stateController =
            TextEditingController(text: _owner?.address.state ?? '');
        countryController =
            TextEditingController(text: _owner?.address.country ?? '');
        postalCodeController =
            TextEditingController(text: _owner?.address.postalCode ?? '');
      });
    } catch (e) {
      print("Error loading profile data: $e");
    }
    setState(() => _isLoading = false);
  }

  void _showFeedbackDialog() {
    final feedbackController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Scaffold(
          appBar: AppBar(
            title: const Text("Send Us Your Feedback!"),
            backgroundColor: const Color(0xFF567D46),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const Text(
                  "We'd love to hear your thoughts, suggestions, or issues.",
                  style: TextStyle(fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: TextField(
                    controller: feedbackController,
                    maxLines: null,
                    expands: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: "Enter your feedback here...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        borderSide: const BorderSide(
                          color: Colors.teal,
                          width: 2.0,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        borderSide: const BorderSide(
                          color: Colors.teal,
                          width: 2.0,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () async {
                    final feedback = feedbackController.text.trim();
                    if (feedback.isEmpty) return;
                    await FirebaseFirestore.instance
                        .collection('feedback')
                        .add({
                      'feedback': feedback,
                      'userId': FirebaseAuth.instance.currentUser?.uid,
                      'timestamp': FieldValue.serverTimestamp(),
                    });
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text("Thank you for your feedback!")),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.tealAccent,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text("Submit"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Navigate to EditProfileScreen and handle the result
  void _navigateToEditProfile() async {
    if (_owner == null) return;

    // ✅ Just update the existing controllers' text
    firstNameController.text = _owner!.firstName;
    lastNameController.text = _owner!.lastName;
    phoneController.text = _owner!.phone;
    emailController.text = _owner!.email;
    streetController.text = _owner!.address.street ?? '';
    cityController.text = _owner!.address.city ?? '';
    stateController.text = _owner!.address.state ?? '';
    countryController.text = _owner!.address.country ?? '';
    postalCodeController.text = _owner!.address.postalCode ?? '';

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(
          firstNameController: firstNameController,
          lastNameController: lastNameController,
          phoneController: phoneController,
          emailController: emailController,
          streetController: streetController,
          cityController: cityController,
          stateController: stateController,
          countryController: countryController,
          postalCodeController: postalCodeController,
        ),
      ),
    );

    if (result == true) {
      await _saveUpdatedOwner(
        firstName: firstNameController.text.trim(),
        lastName: lastNameController.text.trim(),
        phone: phoneController.text.trim(),
      );
    }
  }

  /// Actually update the owner in Firestore
  Future<void> _saveUpdatedOwner({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    if (_owner == null) return;

    final updatedAddress = {
      'street': streetController.text.trim(),
      'city': cityController.text.trim(),
      'state': stateController.text.trim(),
      'country': countryController.text.trim(),
      'postalCode': postalCodeController.text.trim(),
    };

    await FirebaseFirestore.instance.collection('owners').doc(_owner!.uid).set({
      'firstName': firstNameController.text.trim(),
      'lastName': lastNameController.text.trim(),
      'phone': phoneController.text.trim(),
      'address': updatedAddress,
      // ...other fields as needed...
    }, SetOptions(merge: true));

    final updated = Owner(
      uid: _owner!.uid,
      email: _owner!.email,
      locationType: _owner!.locationType,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      pets: _owner!.pets,
      address: Address(
        street: streetController.text.trim(),
        city: cityController.text.trim(),
        state: stateController.text.trim(),
        country: countryController.text.trim(),
        postalCode: postalCodeController.text.trim(),
      ),
    );

    try {
      await _firestoreService.updateOwner(updated);
      setState(() {
        _owner = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Profile updated successfully!")),
      );
    } catch (e) {
      print("Error updating owner: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error updating profile: $e")),
      );
    }
  }

  /// =========== PET LOGIC ===========

  void _showAddPetDialog() {
    if (_owner == null) return;
    final newPetId = FirebaseFirestore.instance.collection('pets').doc().id;

    final nameController = TextEditingController();
    final breedController = TextEditingController();
    String photoUrl = "https://via.placeholder.com/150";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16.0)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 1.0,
          builder: (_, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      "Add Pet",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: "Pet Name"),
                    ),
                    TextField(
                      controller: breedController,
                      decoration: const InputDecoration(
                          labelText: "Pet Breed (optional)"),
                    ),
                    const SizedBox(height: 12),
                    CircleAvatar(
                      radius: 40,
                      backgroundImage: NetworkImage(photoUrl),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.image),
                      label: const Text("Pick Image"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () async {
                        final uploadedUrl =
                            await ImageUploadUtil.pickAndUploadPetPhoto(
                                newPetId);
                        if (uploadedUrl != null) {
                          setState(() {
                            photoUrl = uploadedUrl;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _addPet(
                          petId: newPetId,
                          name: nameController.text.trim(),
                          breed: breedController.text.trim(),
                          photoUrl: photoUrl,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text("Save Pet"),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addPet({
    required String petId,
    required String name,
    required String breed,
    required String photoUrl,
  }) async {
    if (_owner == null) return;
    final pet = Pet(
      id: petId,
      ownerId: _owner!.uid,
      name: name.isEmpty ? "Unnamed Pet" : name,
      photoUrl: photoUrl,
      breed: breed.isEmpty ? null : breed,
      temperament: null,
      weight: null,
      birthday: null,
    );
    try {
      await _firestoreService.addPet(pet);
      setState(() {
        _pets.add(pet);
      });
    } catch (e) {
      print("Error adding pet: $e");
    }
  }

  void _showEditPetSheet(Pet pet) {
    final nameController = TextEditingController(text: pet.name);
    final breedController = TextEditingController(text: pet.breed ?? "");
    String photoUrl = pet.photoUrl;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16.0)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 1.0,
              builder: (_, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          "Edit Pet",
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: nameController,
                          decoration:
                              const InputDecoration(labelText: "Pet Name"),
                        ),
                        TextField(
                          controller: breedController,
                          decoration: const InputDecoration(
                              labelText: "Pet Breed (optional)"),
                        ),
                        const SizedBox(height: 12),
                        CircleAvatar(
                          radius: 40,
                          backgroundImage: NetworkImage(photoUrl),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.image),
                          label: const Text("Change Image"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () async {
                            final uploadedUrl =
                                await ImageUploadUtil.pickAndUploadPetPhoto(
                                    pet.id);
                            if (uploadedUrl != null) {
                              setModalState(() {
                                photoUrl = uploadedUrl;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await _editPet(
                              oldPet: pet,
                              newName: nameController.text.trim(),
                              newBreed: breedController.text.trim(),
                              newPhotoUrl: photoUrl,
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent,
                            foregroundColor: Colors.black,
                          ),
                          child: const Text("Save Changes"),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _editPet({
    required Pet oldPet,
    required String newName,
    required String newBreed,
    required String newPhotoUrl,
  }) async {
    final updatedPet = Pet(
      id: oldPet.id,
      ownerId: oldPet.ownerId,
      name: newName.isEmpty ? "Unnamed Pet" : newName,
      photoUrl: newPhotoUrl,
      breed: newBreed.isEmpty ? null : newBreed,
      temperament: oldPet.temperament,
      weight: oldPet.weight,
      birthday: oldPet.birthday,
    );
    try {
      await _firestoreService.updatePet(updatedPet);
      setState(() {
        final idx = _pets.indexWhere((p) => p.id == oldPet.id);
        if (idx != -1) {
          _pets[idx] = updatedPet;
        }
      });
    } catch (e) {
      print("Error editing pet: $e");
    }
  }

  Future<void> _removePet(String petId) async {
    try {
      await _firestoreService.deletePet(petId);
      setState(() {
        _pets.removeWhere((p) => p.id == petId);
      });
    } catch (e) {
      print("Error removing pet: $e");
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text("Profile"),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF567D46), Color(0xFF365A38)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _owner == null
                  ? const Center(child: CircularProgressIndicator())
                  : SafeArea(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            // Owner Info Card
                            Card(
                              color: Colors.white.withOpacity(0.9),
                              margin: const EdgeInsets.only(bottom: 16.0),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0, vertical: 12.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const CircleAvatar(
                                      radius: 32,
                                      backgroundColor: Colors.black12,
                                      child: Icon(Icons.person,
                                          size: 40, color: Colors.black54),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            "${_owner!.firstName} ${_owner!.lastName}",
                                            style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold),
                                          ),
                                          const SizedBox(height: 4),
                                          Text("Phone: ${_owner!.phone}"),
                                          Text("Email: ${_owner!.email}"),
                                          const SizedBox(height: 4),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _navigateToEditProfile,
                                      icon: const Icon(Icons.edit,
                                          color: Colors.black54),
                                      tooltip: "Edit Profile",
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Pets Header
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "My Pets",
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white),
                                ),
                                ElevatedButton(
                                  onPressed: _showAddPetDialog,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.tealAccent,
                                    foregroundColor: Colors.black,
                                  ),
                                  child: const Text("Add Pet"),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            if (_pets.isEmpty)
                              const Text(
                                "No pets found. Add one above!",
                                style: TextStyle(color: Colors.white70),
                              )
                            else
                              Column(
                                children: _pets.map((pet) {
                                  return Card(
                                    color: Colors.white.withOpacity(0.9),
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundImage:
                                            NetworkImage(pet.photoUrl),
                                        radius: 24,
                                      ),
                                      title: Text(pet.name),
                                      subtitle:
                                          Text(pet.breed ?? "No breed info"),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.edit,
                                                color: Colors.blueGrey),
                                            onPressed: () =>
                                                _showEditPetSheet(pet),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete,
                                                color: Colors.red),
                                            onPressed: () => _removePet(pet.id),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),

                            const SizedBox(height: 32),
                            ElevatedButton.icon(
                              onPressed: _showFeedbackDialog,
                              icon: const Icon(Icons.feedback),
                              label: const Text("Send Us Your Feedback!"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.tealAccent,
                                foregroundColor: Colors.black,
                                minimumSize: const Size.fromHeight(48),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8.0),
                              child: Center(
                                child: SizedBox(
                                  width: 200,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.black,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14.0),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: _logout,
                                    child: const Text("Log Out"),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
        ],
      ),
    );
  }
}
