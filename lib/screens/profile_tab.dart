import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:inthepark/services/firestore_service.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:inthepark/models/pet_model.dart';
import 'package:inthepark/utils/image_upload_util.dart';
import 'package:inthepark/screens/owner_detail_screen.dart';
import 'package:inthepark/screens/edit_profile_screen.dart';
import 'dart:io' show Platform;
import 'package:share_plus/share_plus.dart';

/// ---------- Enticing gradient Share CTA ----------
class ShareAppCta extends StatelessWidget {
  const ShareAppCta({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF00E6A8), Color(0xFF00B386)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isIOS ? CupertinoIcons.share : Icons.share,
                  color: Colors.white,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      'Share In The Park To Your Friends!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Invite a friend — it’s free',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProfileTab extends StatefulWidget {
  const ProfileTab({Key? key}) : super(key: key);

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final _firestoreService = FirestoreService();

  // Controllers (initialized immediately to avoid late-init issues)
  final firstNameController = TextEditingController();
  final lastNameController = TextEditingController();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();
  final streetController = TextEditingController();
  final cityController = TextEditingController();
  final stateController = TextEditingController();
  final countryController = TextEditingController();
  final postalCodeController = TextEditingController();

  bool _isLoading = true;
  Owner? _owner;
  List<Pet> _pets = [];

  // For sheet upload spinners (add/edit pet)
  bool _sheetUploading = false;

  @override
  void initState() {
    super.initState();
    // auto-uppercase postal code as user types (works in the editor too)
    postalCodeController.addListener(_autoUppercasePostal);
    _loadOwnerAndPets();
  }

  void _autoUppercasePostal() {
    final text = postalCodeController.text;
    final upper = text.toUpperCase();
    if (text != upper) {
      final sel = postalCodeController.selection; // preserve cursor
      postalCodeController.value = TextEditingValue(
        text: upper,
        selection: sel,
        composing: TextRange.empty,
      );
    }
  }

  @override
  void dispose() {
    firstNameController.dispose();
    lastNameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    streetController.dispose();
    cityController.dispose();
    stateController.dispose();
    countryController.dispose();
    postalCodeController.removeListener(_autoUppercasePostal);
    postalCodeController.dispose();
    super.dispose();
  }

  // ---------- UI helpers ----------

  void _shareApp() {
    const androidUrl =
        'https://play.google.com/store/apps/details?id=ca.inthepark&pcampaignid=web_share';
    const iosUrl = 'https://apps.apple.com/ca/app/in-the-park/id6752841263';

    final link = Platform.isAndroid
        ? androidUrl
        : (Platform.isIOS ? iosUrl : '$androidUrl\n$iosUrl');

    Share.share(
      'Check out In The Park! $link',
      subject: 'In The Park',
    );
  }

  InputDecoration _outlinedDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: Colors.black.withOpacity(0.15),
          width: 1,
        ),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Colors.teal, width: 2),
      ),
    );
  }

  BoxDecoration _glassCardDecoration({bool lightOnGreen = true}) {
    final base = lightOnGreen ? Colors.white : Colors.black;
    return BoxDecoration(
      color: lightOnGreen ? Colors.white.withOpacity(0.9) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: base.withOpacity(0.10)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.12),
          blurRadius: 18,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  // ---------- Data ----------

  Future<void> _loadOwnerAndPets() async {
    setState(() => _isLoading = true);
    try {
      final owner = await _firestoreService.getOwner();
      if (owner == null) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const OwnerDetailsScreen()),
          );
        }
        return;
      }

      final pets = await _firestoreService.getPetsForOwner(owner.uid);

      // Fill controllers
      firstNameController.text = owner.firstName;
      lastNameController.text = owner.lastName;
      phoneController.text = owner.phone;
      emailController.text = owner.email;
      streetController.text = owner.address.street ?? '';
      cityController.text = owner.address.city ?? '';
      stateController.text = owner.address.state ?? '';
      countryController.text = owner.address.country ?? '';
      postalCodeController.text = owner.address.postalCode ?? '';

      setState(() {
        _owner = owner;
        _pets = pets;
      });
    } catch (e) {
      debugPrint("Error loading profile data: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

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
      'postalCode': postalCodeController.text.trim().toUpperCase(), // ← here
    };

    await FirebaseFirestore.instance.collection('owners').doc(_owner!.uid).set({
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'address': updatedAddress,
      'updatedAt': FieldValue.serverTimestamp(),
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
        postalCode: postalCodeController.text.trim().toUpperCase(),
      ),
    );

    try {
      await _firestoreService.updateOwner(updated);
      if (!mounted) return;
      setState(() => _owner = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Profile updated successfully!")),
      );
    } catch (e) {
      debugPrint("Error updating owner: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error updating profile: $e")),
      );
    }
  }

  // ---------- Feedback ----------

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
                    decoration:
                        _outlinedDecoration("Enter your feedback here..."),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share),
                    label: const Text('Share this app'),
                    onPressed: _shareApp,
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final feedback = feedbackController.text.trim();
                    if (feedback.isEmpty) return;

                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text("Please sign in to send feedback.")),
                      );
                      return;
                    }

                    try {
                      await FirebaseFirestore.instance
                          .collection('feedback')
                          .add({
                        'feedback': feedback,
                        'userId': user.uid,
                        'timestamp': FieldValue.serverTimestamp(),
                      });
                      if (!mounted) return;
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text("Thank you for your feedback!")),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Couldn’t send feedback: $e")),
                      );
                    }
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

  // ---------- Add / Edit Pet Sheets (modern UI + avatar loader) ----------

  Future<void> _showAddPetDialog() async {
    if (_owner == null) return;

    final newPetId = FirebaseFirestore.instance.collection('pets').doc().id;
    final nameController = TextEditingController();
    final breedController = TextEditingController();
    String? photoUrl; // stays null until user uploads
    _sheetUploading = false;
    bool triedSave = false; // show error only after first save attempt

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _ModernSheet(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> pickImage() async {
                setSheetState(() => _sheetUploading = true);
                final uploaded =
                    await ImageUploadUtil.pickAndUploadPetPhoto(newPetId);
                setSheetState(() {
                  photoUrl = uploaded;
                  _sheetUploading = false;
                });
              }

              final name = nameController.text.trim();
              final nameEmpty = name.isEmpty;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SheetHeader(title: "Add Pet"),
                  const SizedBox(height: 12),
                  _AvatarPicker(
                    imageUrl: photoUrl,
                    isUploading: _sheetUploading,
                    onTap: pickImage,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    decoration: _outlinedDecoration("Pet name").copyWith(
                      errorText: (triedSave && nameEmpty)
                          ? "Pet name is required"
                          : null,
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: breedController,
                    decoration: _outlinedDecoration("Pet breed (optional)"),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black87,
                            side: const BorderSide(color: Colors.black26),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text("Cancel"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (_sheetUploading || nameEmpty)
                              ? null
                              : () async {
                                  Navigator.of(context).pop();
                                  await _addPet(
                                    petId: newPetId,
                                    name: name,
                                    breed: breedController.text.trim(),
                                    photoUrl:
                                        photoUrl, // nullable; defaulted inside
                                  );
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text("Save Pet"),
                        ),
                      ),
                    ],
                  ),
                  if (!_sheetUploading && nameEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Builder(
                          builder: (ctx) {
                            if (!triedSave) {
                              Future.microtask(() {
                                setSheetState(() => triedSave = true);
                              });
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                    ),
                  SizedBox(
                      height: MediaQuery.of(context).viewInsets.bottom + 6),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showEditPetSheet(Pet pet) async {
    final nameController = TextEditingController(text: pet.name);
    final breedController = TextEditingController(text: pet.breed ?? "");
    String? photoUrl = pet.photoUrl; // start with current
    _sheetUploading = false;
    bool triedSave = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _ModernSheet(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> pickImage() async {
                setSheetState(() => _sheetUploading = true);
                final uploaded =
                    await ImageUploadUtil.pickAndUploadPetPhoto(pet.id);
                setSheetState(() {
                  if (uploaded != null) photoUrl = uploaded;
                  _sheetUploading = false;
                });
              }

              final name = nameController.text.trim();
              final nameEmpty = name.isEmpty;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SheetHeader(title: "Edit Pet"),
                  const SizedBox(height: 12),
                  _AvatarPicker(
                    imageUrl: photoUrl,
                    isUploading: _sheetUploading,
                    onTap: pickImage,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    decoration: _outlinedDecoration("Pet name").copyWith(
                      errorText: (triedSave && nameEmpty)
                          ? "Pet name is required"
                          : null,
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: breedController,
                    decoration: _outlinedDecoration("Pet breed (optional)"),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black87,
                            side: const BorderSide(color: Colors.black26),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text("Cancel"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (_sheetUploading || nameEmpty)
                              ? null
                              : () async {
                                  Navigator.of(context).pop();
                                  await _editPet(
                                    oldPet: pet,
                                    newName: name,
                                    newBreed: breedController.text.trim(),
                                    newPhotoUrl:
                                        photoUrl, // nullable; handled inside
                                  );
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text("Save Changes"),
                        ),
                      ),
                    ],
                  ),
                  if (!_sheetUploading && nameEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Builder(
                          builder: (ctx) {
                            if (!triedSave) {
                              Future.microtask(() {
                                setSheetState(() => triedSave = true);
                              });
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                    ),
                  SizedBox(
                      height: MediaQuery.of(context).viewInsets.bottom + 6),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // ---------- Pet data ops ----------

  Future<void> _addPet({
    required String petId,
    required String name,
    required String breed,
    String? photoUrl, // nullable incoming
  }) async {
    if (_owner == null) return;

    final pet = Pet(
      id: petId,
      ownerId: _owner!.uid,
      name: name.isEmpty ? "Unnamed Pet" : name,
      photoUrl: (photoUrl == null || photoUrl.isEmpty) ? null : photoUrl,
      breed: breed.isEmpty ? null : breed,
      temperament: null,
      weight: null,
      birthday: null,
    );

    try {
      await _firestoreService.addPet(pet);
      if (!mounted) return;
      setState(() => _pets.add(pet));
    } catch (e) {
      debugPrint("Error adding pet: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error adding pet: $e")),
      );
    }
  }

  Future<void> _editPet({
    required Pet oldPet,
    required String newName,
    required String newBreed,
    String? newPhotoUrl, // nullable – keep old if null
  }) async {
    final updatedPet = Pet(
      id: oldPet.id,
      ownerId: oldPet.ownerId,
      name: newName.isEmpty ? "Unnamed Pet" : newName,
      photoUrl: (newPhotoUrl == null || newPhotoUrl.isEmpty)
          ? oldPet.photoUrl
          : newPhotoUrl,
      breed: newBreed.isEmpty ? null : newBreed,
      temperament: oldPet.temperament,
      weight: oldPet.weight,
      birthday: oldPet.birthday,
    );
    try {
      await _firestoreService.updatePet(updatedPet);
      if (!mounted) return;
      setState(() {
        final idx = _pets.indexWhere((p) => p.id == oldPet.id);
        if (idx != -1) _pets[idx] = updatedPet;
      });
    } catch (e) {
      debugPrint("Error editing pet: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error editing pet: $e")),
      );
    }
  }

  Future<void> _removePet(String petId) async {
    try {
      await _firestoreService.deletePet(petId);
      if (!mounted) return;
      setState(() => _pets.removeWhere((p) => p.id == petId));
    } catch (e) {
      debugPrint("Error removing pet: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error removing pet: $e")),
      );
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/login');
  }

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        title: const Text("Profile"),
        backgroundColor: const Color(0xFF567D46),
        elevation: 2,
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
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_owner == null)
            const Center(child: CircularProgressIndicator())
          else
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Owner Info Card (glassy)
                    Container(
                      decoration: _glassCardDecoration(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 14.0,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "${_owner!.firstName} ${_owner!.lastName}",
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text("Phone: ${_owner!.phone}"),
                                Text("Email: ${_owner!.email}"),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _navigateToEditProfile,
                            icon: const Icon(Icons.edit, color: Colors.black54),
                            tooltip: "Edit Profile",
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Pets header + add
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "My Pets",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
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
                          // Safe check for a non-empty URL
                          final photo = pet.photoUrl ?? '';
                          final hasPhoto = photo.trim().isNotEmpty;
                          final ImageProvider? petImage =
                              hasPhoto ? NetworkImage(photo) : null;

                          return Container(
                            decoration: _glassCardDecoration(),
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              leading: CircleAvatar(
                                radius: 24,
                                backgroundColor: Colors.black12,
                                backgroundImage: petImage,
                                child: petImage == null
                                    ? const Icon(Icons.pets,
                                        color: Colors.black45)
                                    : null,
                              ),
                              title: Text(pet.name),
                              subtitle: Text(pet.breed ?? "No breed info"),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit,
                                        color: Colors.blueGrey),
                                    onPressed: () => _showEditPetSheet(pet),
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

                    // Feedback button
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

                    const SizedBox(height: 12),

                    // NEW: Enticing “Share this app” CTA
                    ShareAppCta(onPressed: _shareApp),

                    const SizedBox(height: 20),

                    // Logout
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Center(
                        child: SizedBox(
                          width: 200,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14.0),
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

  // ---------- Navigation to profile editor ----------

  void _navigateToEditProfile() async {
    if (_owner == null) return;

    // Ensure controllers have latest values
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
}

// ===================== Reusable Sheet Pieces =====================

class _ModernSheet extends StatelessWidget {
  const _ModernSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: SingleChildScrollView(
            controller: controller,
            child: child,
          ),
        );
      },
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 44,
          height: 5,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.imageUrl,
    required this.isUploading,
    required this.onTap,
  });

  final String? imageUrl;
  final bool isUploading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isUploading ? Colors.teal : Colors.black12,
                width: isUploading ? 3 : 1.5,
              ),
              boxShadow: [
                if (!isUploading)
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
              ],
            ),
            child: CircleAvatar(
              radius: 48,
              backgroundColor: Colors.black12,
              backgroundImage:
                  (imageUrl != null && imageUrl!.isNotEmpty && !isUploading)
                      ? NetworkImage(imageUrl!)
                      : null,
              child: (imageUrl == null || imageUrl!.isEmpty || isUploading)
                  ? const Icon(Icons.pets, size: 34, color: Colors.black45)
                  : null,
            ),
          ),
          if (isUploading)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.22),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
              ),
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: Colors.tealAccent,
                shape: BoxShape.circle,
              ),
              child:
                  const Icon(Icons.camera_alt, size: 16, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}
