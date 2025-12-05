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
import 'package:inthepark/widgets/rewarded_streak_ads.dart';
import 'dart:io' show Platform;
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'dart:ui' as ui;
import 'dart:async';
import 'package:inthepark/widgets/ad_banner.dart';

class VisitHistoryCta extends StatelessWidget {
  const VisitHistoryCta({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          // subtle “frosted glass” on top of your green gradient
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF567D46),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.park, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Visit History',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right,
                    color: Colors.black.withOpacity(0.55)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
  const ProfileTab({Key? key, this.onGoToMapTab}) : super(key: key);

  /// Parent passes this to switch tabs (e.g. bottom nav index or TabController)
  final VoidCallback? onGoToMapTab;

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
  bool _revivingStreak = false;

  @override
  void initState() {
    super.initState();
    // auto-uppercase postal code as user types (works in the editor too)
    postalCodeController.addListener(_autoUppercasePostal);
    _loadOwnerAndPets();
  }

  void _openWalksList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WalksListScreen(onGoToMapTab: widget.onGoToMapTab),
      ),
    );
  }

  Future<void> _confirmAndDeletePet(Pet pet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${pet.name}?'),
        content: const Text('This will permanently remove this pet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await _removePet(pet.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${pet.name}')),
      );
    }
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

  void _openVisitHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const VisitHistoryScreen()),
    );
  }

  String _dayKeyLocal(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// TODO: wire to your real rewarded-ad flow; return true only if the user
  /// fully completes the ad.
  Future<bool> _watchReviveAd() async {
    final c = Completer<bool>();

    await RewardedStreakAds.show(
      onRewardEarned: (r) {
        if (!c.isCompleted) c.complete(true);
      },
      onDismissed: () {
        if (!c.isCompleted) c.complete(false);
      },
      onFailedToShow: (msg) {
        if (!c.isCompleted) c.complete(false);
        if (mounted && msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      },
    );

    return c.future;
  }

  /// Atomically revive **yesterday** in owners/{uid}/stats/walkStreak
  /// if the streak broke exactly the day before yesterday and hasn't been revived.
  Future<void> _applyStreakReviveAfterReward() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw 'Not signed in';

    String dayKey(DateTime d) {
      final dd = DateTime(d.year, d.month, d.day);
      final mm = dd.month.toString().padLeft(2, '0');
      final dd2 = dd.day.toString().padLeft(2, '0');
      return '${dd.year}-$mm-$dd2';
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yKey = dayKey(today.subtract(const Duration(days: 1))); // yesterday
    final dbyKey =
        dayKey(today.subtract(const Duration(days: 2))); // day-before-yesterday

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) {
        throw 'No streak to revive.';
      }
      final data = snap.data() as Map<String, dynamic>;
      int current = (data['current'] ?? 0) as int;
      int longest = (data['longest'] ?? 0) as int;
      final lastDate = (data['lastDate'] as String?)?.trim();
      final alreadyRevivedFor = (data['revivedForDay'] as String?)?.trim();

      // Eligible only if the break was exactly yesterday (meaning lastDate == DBY)
      if (lastDate != dbyKey) {
        throw 'Revive not eligible (break wasn’t yesterday).';
      }
      if (alreadyRevivedFor == yKey) {
        throw 'Yesterday already revived.';
      }

      current += 1;
      if (current > longest) longest = current;

      txn.set(
        docRef,
        {
          'current': current,
          'longest': longest,
          'lastDate': yKey, // move lastDate forward to yesterday
          'revivedForDay': yKey, // record the revived day
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
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

  Widget _buildStreakCard() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final doc = FirebaseFirestore.instance
        .collection('owners')
        .doc(user.uid)
        .collection('stats')
        .doc('walkStreak')
        .snapshots();

    String days(int n) => '$n day${n == 1 ? '' : 's'}';

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: doc,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Container(
            decoration: _glassCardDecoration(),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: const [
                SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('Loading streak...',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }

        final data = snap.data?.data() ?? const {};
        final current = (data['current'] as num?)?.toInt() ?? 0;
        final longest = (data['longest'] as num?)?.toInt() ?? 0;
        final lastDate = (data['lastDate'] as String?)?.trim();
        final revivedForDay = (data['revivedForDay'] as String?)?.trim();

        // Revive eligibility: break happened yesterday → lastDate == day-before-yesterday
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final yesterdayKey =
            _dayKeyLocal(today.subtract(const Duration(days: 1)));
        final dbyKey = _dayKeyLocal(today.subtract(const Duration(days: 2)));
        final eligible = lastDate == dbyKey && revivedForDay != yesterdayKey;

        return Material(
          color: Colors.transparent,
          child: Ink(
            decoration: _glassCardDecoration(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row + quick nav to walks
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF7A59),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.local_fire_department,
                            color: Colors.white, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Current Streak: ${days(current)}',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text('Best: ${days(longest)}',
                                style: TextStyle(
                                    color: Colors.black.withOpacity(0.7),
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _MiniHintPill(text: 'History', onTap: _openWalksList),
                      const Icon(Icons.chevron_right, color: Colors.black54),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Revive CTA (only when eligible)
                  if (eligible)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: _revivingStreak
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.2))
                            : const Icon(Icons.favorite),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF567D46),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        label: Text(
                          _revivingStreak
                              ? 'Reviving…'
                              : 'You’ve come this far — don’t break the streak! Revive it and stay on fire! 🔥',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800),
                        ),
                        onPressed: _revivingStreak
                            ? null
                            : () async {
                                setState(() => _revivingStreak = true);
                                try {
                                  final ok = await _watchReviveAd();
                                  if (!ok) {
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Ad not completed. Revive cancelled.')),
                                    );
                                  } else {
                                    await _applyStreakReviveAfterReward();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Streak revived! Keep it going!🔥')),
                                    );
                                  }
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text('Revive failed: $e')));
                                } finally {
                                  if (mounted) {
                                    setState(() => _revivingStreak = false);
                                  }
                                }
                              },
                      ),
                    )
                  else
                    const Text('Keep up the daily walks! 🎉',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------- UI helpers ----------

  void _shareApp() {
    const androidUrl =
        'https://play.google.com/store/apps/details?id=ca.inthepark&pcampaignid=web_share';
    const iosUrl = 'https://apps.apple.com/ca/app/in-the-park/id6752841263';

    Share.share(
      'Check out In The Park!\n\niOS: $iosUrl\nAndroid: $androidUrl',
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
                    _buildStreakCard(),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: VisitHistoryCta(onTap: _openVisitHistory),
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
                                    onPressed: () => _confirmAndDeletePet(pet),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 16),

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
      bottomNavigationBar: const SafeArea(
        child: AdBanner(), // uses your adaptive banner + auto init/consent hook
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

class ReviveStreakBanner extends StatefulWidget {
  const ReviveStreakBanner({super.key});

  @override
  State<ReviveStreakBanner> createState() => _ReviveStreakBannerState();
}

class WalksListScreen extends StatelessWidget {
  final VoidCallback? onGoToMapTab;

  const WalksListScreen({super.key, this.onGoToMapTab});

  // --- Small helpers ---
  String _fmtTotalDuration(int s) {
    if (s <= 0) return '0m';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Walks'),
        backgroundColor: const Color(0xFF567D46),
        elevation: 2,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF567D46), Color(0xFF365A38)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: user == null
            ? const Center(
                child: Text(
                  'Please sign in to view your walks.',
                  style: TextStyle(color: Colors.white),
                ),
              )
            : StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('owners')
                    .doc(user.uid)
                    .collection('walks')
                    .orderBy('startedAt', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Text(
                        'Error: ${snap.error}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }
                  final docs = snap.data?.docs ?? [];

                  // ---------- EMPTY STATE ----------
                  if (docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24.0),
                            child: Text(
                              'No walks yet? Your next adventure starts now — grab the leash and explore!',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                height: 1.4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          ElevatedButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              onGoToMapTab?.call();
                            },
                            icon: const Icon(Icons.pets, color: Colors.black),
                            label: const Text(
                              'Start Walking 🐾',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15.5,
                                color: Colors.black,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.tealAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              shadowColor: Colors.black.withOpacity(0.2),
                              elevation: 4,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // ---------- GROUP WALKS BY DAY ----------
                  final Map<DateTime, List<QueryDocumentSnapshot>> byDay = {};
                  for (final doc in docs) {
                    final data = doc.data() as Map<String, dynamic>? ?? {};
                    final startedAt =
                        (data['startedAt'] as Timestamp?)?.toDate();
                    final dayKey = startedAt != null
                        ? DateTime(
                            startedAt.year, startedAt.month, startedAt.day)
                        : DateTime.fromMillisecondsSinceEpoch(0); // sentinel
                    byDay.putIfAbsent(dayKey, () => []).add(doc);
                  }

                  // sort newest day first; move "unknown" to end
                  final days = byDay.keys.toList()
                    ..sort((a, b) {
                      if (a.millisecondsSinceEpoch == 0) return 1;
                      if (b.millisecondsSinceEpoch == 0) return -1;
                      return b.compareTo(a);
                    });

                  final NumberFormat stepsFmt = NumberFormat.decimalPattern();

                  // ---------- LIST WITH REVIVE BANNER ----------
                  return Column(
                    children: [
                      const ReviveStreakBanner(), // only shows when eligible
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          itemCount: days.length,
                          itemBuilder: (context, dayIndex) {
                            final day = days[dayIndex];
                            final dayDocs = byDay[day]!;

                            final totalSteps = dayDocs.fold<int>(0, (sum, d) {
                              final m = d.data() as Map<String, dynamic>? ?? {};
                              return sum + ((m['steps'] as num?)?.toInt() ?? 0);
                            });

                            final totalDurationSec =
                                dayDocs.fold<int>(0, (sum, d) {
                              final m = d.data() as Map<String, dynamic>? ?? {};
                              final startedAt =
                                  (m['startedAt'] as Timestamp?)?.toDate();
                              final endedAt =
                                  (m['endedAt'] as Timestamp?)?.toDate();
                              final stored =
                                  (m['durationSec'] as num?)?.toInt();
                              final dur = stored ??
                                  ((startedAt != null && endedAt != null)
                                      ? endedAt.difference(startedAt).inSeconds
                                      : 0);
                              return sum + dur;
                            });

                            String dateLabel;
                            if (day.millisecondsSinceEpoch == 0) {
                              dateLabel = 'Unknown date';
                            } else {
                              final now = DateTime.now();
                              final today =
                                  DateTime(now.year, now.month, now.day);
                              final yesterday =
                                  today.subtract(const Duration(days: 1));
                              final dOnly =
                                  DateTime(day.year, day.month, day.day);
                              if (dOnly == today) {
                                dateLabel = 'Today';
                              } else if (dOnly == yesterday) {
                                dateLabel = 'Yesterday';
                              } else {
                                dateLabel =
                                    DateFormat('EEE, MMM d, yyyy').format(day);
                              }
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _DayHeader(
                                  label: dateLabel,
                                  stepsText:
                                      '${stepsFmt.format(totalSteps)} steps • ${_fmtTotalDuration(totalDurationSec)}',
                                ),
                                const SizedBox(height: 8),
                                ...dayDocs.map((doc) {
                                  final d =
                                      doc.data() as Map<String, dynamic>? ?? {};
                                  final id = doc.id;

                                  final startedAt =
                                      (d['startedAt'] as Timestamp?)?.toDate();
                                  final endedAt =
                                      (d['endedAt'] as Timestamp?)?.toDate();

                                  final distanceMeters =
                                      (d['distanceMeters'] as num?)
                                              ?.toDouble() ??
                                          0.0;
                                  final steps =
                                      (d['steps'] as num?)?.toInt() ?? 0;

                                  final storedDur =
                                      (d['durationSec'] as num?)?.toInt();
                                  final durationSec = storedDur ??
                                      ((startedAt != null && endedAt != null)
                                          ? endedAt
                                              .difference(startedAt)
                                              .inSeconds
                                          : 0);

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: _WalkCard(
                                      id: id,
                                      startedAt: startedAt,
                                      distanceMeters: distanceMeters,
                                      durationSec: durationSec,
                                      steps: steps,
                                      onDelete: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Delete walk?'),
                                            content: const Text(
                                              'This will permanently remove the walk.',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: const Text('Cancel'),
                                              ),
                                              ElevatedButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child: const Text('Delete'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await FirebaseFirestore.instance
                                              .collection('owners')
                                              .doc(user.uid)
                                              .collection('walks')
                                              .doc(id)
                                              .delete();
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                  content:
                                                      Text('Walk deleted')),
                                            );
                                          }
                                        }
                                      },
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                WalkDetailScreen(walkId: id),
                                          ),
                                        );
                                      },
                                    ),
                                  );
                                }),
                                const SizedBox(height: 8),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

///
/// ReviveStreakBanner
/// Shows a single-line card with a CTA to revive *yesterday* if the streak broke
/// exactly the day before yesterday and hasn't already been revived for yesterday.
///

class _ReviveStreakBannerState extends State<ReviveStreakBanner> {
  bool _reviving = false;

  String _dayKey(DateTime d) {
    final dd = DateTime(d.year, d.month, d.day);
    final mm = dd.month.toString().padLeft(2, '0');
    final dd2 = dd.day.toString().padLeft(2, '0');
    return '${dd.year}-$mm-$dd2';
  }

  Future<bool> _watchReviveAd() async {
    final c = Completer<bool>();
    await RewardedStreakAds.show(
      onRewardEarned: (_) {
        if (!c.isCompleted) c.complete(true);
      },
      onDismissed: () {
        if (!c.isCompleted) c.complete(false);
      },
      onFailedToShow: (msg) {
        if (!c.isCompleted) c.complete(false);
        if (mounted && msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      },
    );
    return c.future;
  }

  Future<void> _applyReviveForYesterday() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw 'Not signed in';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yKey = _dayKey(today.subtract(const Duration(days: 1)));
    final dbyKey = _dayKey(today.subtract(const Duration(days: 2)));

    final docRef = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('stats')
        .doc('walkStreak');

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) throw 'No streak to revive.';

      final data = snap.data() as Map<String, dynamic>;
      int current = (data['current'] ?? 0) as int;
      int longest = (data['longest'] ?? 0) as int;
      final lastDate = (data['lastDate'] as String?)?.trim();
      final alreadyRevivedFor = (data['revivedForDay'] as String?)?.trim();

      if (lastDate != dbyKey) {
        throw 'Revive not eligible (break wasn’t yesterday).';
      }
      if (alreadyRevivedFor == yKey) {
        throw 'Yesterday already revived.';
      }

      current += 1;
      if (current > longest) longest = current;

      txn.set(
        docRef,
        {
          'current': current,
          'longest': longest,
          'lastDate': yKey,
          'revivedForDay': yKey,
          'canRevive': false,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final streakDoc = FirebaseFirestore.instance
        .collection('owners')
        .doc(user.uid)
        .collection('stats')
        .doc('walkStreak')
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: streakDoc,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 8);

        final data = snap.data!.data() ?? {};
        final lastDate = (data['lastDate'] as String?)?.trim();
        final revivedForDay = (data['revivedForDay'] as String?)?.trim();

        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final yKey = _dayKey(today.subtract(const Duration(days: 1)));
        final dbyKey = _dayKey(today.subtract(const Duration(days: 2)));

        final eligible = lastDate == dbyKey && revivedForDay != yKey;
        if (!eligible) return const SizedBox(height: 8);

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.black.withOpacity(0.06)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF7A59),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.local_fire_department,
                          color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        "Don’t let your streak fade — revive it now and keep the fire going! 🔥",
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _reviving
                          ? null
                          : () async {
                              setState(() => _reviving = true);
                              try {
                                final ok = await _watchReviveAd();
                                if (!ok) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Ad not completed. Revive cancelled.')),
                                  );
                                } else {
                                  await _applyReviveForYesterday();
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Streak revived! Keep it going!🔥')),
                                  );
                                }
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Revive failed: $e')),
                                );
                              } finally {
                                if (mounted) setState(() => _reviving = false);
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF567D46),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: _reviving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : const Text(
                              'Revive',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 14),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WalkCard extends StatelessWidget {
  const _WalkCard({
    required this.id,
    required this.startedAt,
    required this.distanceMeters,
    required this.durationSec,
    required this.steps,
    required this.onDelete,
    required this.onTap,
  });

  final String id;
  final DateTime? startedAt;
  final double distanceMeters;
  final int durationSec;
  final int steps;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  String _fmtDate(DateTime? dt) {
    if (dt == null) return 'Unknown date';
    return DateFormat('EEE, MMM d, yyyy • h:mm a').format(dt);
    // e.g., Tue, Sep 30, 2025 • 6:42 PM
  }

  String _fmtDistance(double m) {
    if (m >= 1000) {
      return '${(m / 1000).toStringAsFixed(2)} km';
    }
    return '${m.toStringAsFixed(0)} m';
  }

  String _fmtDuration(int s) {
    if (s <= 0) return '—';
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m ${sec}s';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onDelete, // long-press to delete
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF567D46),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.directions_walk,
                      color: Colors.white, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fmtDate(startedAt),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 6,
                        children: [
                          _Pill(text: _fmtDistance(distanceMeters)),
                          _Pill(text: _fmtDuration(durationSec)),
                          _Pill(text: '$steps steps'),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.black54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class WalkDetailScreen extends StatefulWidget {
  const WalkDetailScreen({super.key, required this.walkId});
  final String walkId;

  @override
  State<WalkDetailScreen> createState() => _WalkDetailScreenState();
}

class _WalkDetailScreenState extends State<WalkDetailScreen> {
  GoogleMapController? _mapController;
  final Completer<GoogleMapController> _ctlCompleter = Completer();

  bool _loading = true;
  Set<Polyline> _polylines = {};
  final Map<String, Marker> _markers = {};
  LatLng? _focus;

  // custom icons
  BitmapDescriptor? _peeIcon;
  BitmapDescriptor? _poopIcon;
  BitmapDescriptor? _cautionIcon;

  @override
  void initState() {
    super.initState();
    _loadWalk();
  }

  // ---------- Bitmaps ----------
  Future<void> _ensureNoteIcons() async {
    _peeIcon ??= await _bitmapFromAsset('assets/icon/pee.png', width: 96);
    _poopIcon ??= await _bitmapFromAsset('assets/icon/poop.png', width: 96);
    _cautionIcon ??= await _bitmapFromIcon(Icons.warning_amber_rounded,
        fg: Colors.black87, bg: Colors.amber.shade600);
  }

  Future<BitmapDescriptor> _bitmapFromAsset(String assetPath,
      {int width = 96}) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(),
        targetWidth: width, targetHeight: width);
    final frame = await codec.getNextFrame();
    final byteData =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _bitmapFromIcon(IconData icon,
      {required Color fg, required Color bg, double size = 96}) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..color = bg;
    final radius = size / 2;
    final center = ui.Offset(radius, radius);
    canvas.drawCircle(center, radius, paint);

    final tp = TextPainter(
        textDirection: ui.TextDirection.ltr, textAlign: TextAlign.center);
    tp.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: size * 0.58,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: fg,
      ),
    );
    tp.layout();
    tp.paint(
        canvas, ui.Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));

    final img =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  void _showNoteSheet({
    required String title,
    required String? message,
    required LatLng pos,
  }) {
    final msg = (message == null || message.trim().isEmpty)
        ? '(no message)'
        : message.trim();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (title.toLowerCase() == 'caution')
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.black87)
                  else if (title.toLowerCase() == 'pee')
                    const ImageIcon(
                      AssetImage('assets/icon/pee.png'),
                      size: 24,
                      color: Colors.black87,
                    )
                  else
                    const Icon(Icons.pets, color: Colors.black87),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                msg,
                style: const TextStyle(fontSize: 15.5, color: Colors.black87),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Lat: ${pos.latitude.toStringAsFixed(5)}  '
                    'Lng: ${pos.longitude.toStringAsFixed(5)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.black.withOpacity(0.55),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: msg));
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Message copied')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- Data load ----------
  Future<void> _loadWalk() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please sign in.')),
          );
        }
        return;
      }

      await _ensureNoteIcons();

      final walkRef = FirebaseFirestore.instance
          .collection('owners') // matches your security rules
          .doc(user.uid)
          .collection('walks')
          .doc(widget.walkId);

      final walkSnap = await walkRef.get();
      if (!walkSnap.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Walk not found.')));
        }
        return;
      }

      final data = walkSnap.data()!;
      final List<dynamic> routeRaw = (data['route'] ?? []) as List<dynamic>;
      final pts = <LatLng>[];
      for (final item in routeRaw) {
        if (item is GeoPoint) {
          pts.add(LatLng(item.latitude, item.longitude));
        } else if (item is Map && item['lat'] != null && item['lng'] != null) {
          pts.add(LatLng((item['lat'] as num).toDouble(),
              (item['lng'] as num).toDouble()));
        }
      }

      // Build polyline
      if (pts.isNotEmpty) {
        _polylines = {
          Polyline(
            polylineId: PolylineId('walk_${widget.walkId}'),
            points: pts,
            width: 6,
            color: Colors.blueAccent,
            geodesic: true,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };
        _focus = pts.first;
      }

      // Load notes
      try {
        final notesSnap = await walkRef.collection('notes').get();
        for (final d in notesSnap.docs) {
          final n = d.data();
          final type = (n['type'] ?? '') as String;

          // Be defensive about the message field name
          final rawMsg = (n['message'] ??
              n['text'] ??
              n['note'] ??
              n['details']) as String?;
          final msg = rawMsg?.toString().trim();
          final pos = n['position'];

          if (pos is! GeoPoint) continue;

          BitmapDescriptor icon;
          String title;
          switch (type) {
            case 'pee':
              icon = _peeIcon!;
              title = 'Pee';
            case 'poop':
              icon = _poopIcon!;
              title = 'Poop';
            default:
              icon = _cautionIcon!;
              title = 'Caution';
          }

          final latLng = LatLng(pos.latitude, pos.longitude);

          _markers[d.id] = Marker(
            markerId: MarkerId(d.id),
            position: latLng,
            icon: icon,
            infoWindow: InfoWindow(
              title: title,
              // Keep a short snippet for quick glance (falls back if empty)
              snippet: (msg == null || msg.isEmpty) ? null : msg,
              // On info window tap, show the full sheet too
              onTap: () =>
                  _showNoteSheet(title: title, message: msg, pos: latLng),
            ),
            // On marker tap, always open the bottom sheet so long texts aren't truncated
            onTap: () =>
                _showNoteSheet(title: title, message: msg, pos: latLng),
          );
        }
      } catch (_) {
        // Silently ignore; the map will still show the route.
      }

      setState(() => _loading = false);

      // Focus camera
      final ctl = _mapController ?? await _ctlCompleter.future;
      if (_focus != null) {
        await ctl.animateCamera(CameraUpdate.newLatLngZoom(_focus!, 16));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error loading walk: $e')));
    }
  }

  void _onMapCreated(GoogleMapController c) {
    _mapController = c;
    if (!_ctlCompleter.isCompleted) _ctlCompleter.complete(c);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk Details'),
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
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            GoogleMap(
              onMapCreated: _onMapCreated,
              initialCameraPosition: CameraPosition(
                target: _focus ?? const LatLng(43.7615, -79.4111),
                zoom: _focus == null ? 12 : 16,
              ),
              markers: _markers.values.toSet(),
              polylines: _polylines,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              compassEnabled: true,
            ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.stepsText});

  final String label;
  final String stepsText;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.15),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withOpacity(0.25)),
          ),
          child: Text(
            stepsText,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniHintPill extends StatelessWidget {
  const _MiniHintPill({required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    if (onTap == null) return pill;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

class VisitHistoryScreen extends StatelessWidget {
  const VisitHistoryScreen({super.key});

  String _fmtRange(Timestamp? inTs, Timestamp? outTs) {
    final inDt = inTs?.toDate();
    final outDt = outTs?.toDate();

    if (inDt == null) return 'Unknown time';
    final inStr = DateFormat('h:mm a').format(inDt);
    final outStr = (outDt != null) ? DateFormat('h:mm a').format(outDt) : '—';
    return '$inStr → $outStr';
  }

  String _fmtDuration(num? minutes) {
    final m = (minutes ?? 0).toInt();
    if (m <= 0) return '—';
    final h = m ~/ 60;
    final r = m % 60;
    if (h > 0 && r > 0) return '${h}h ${r}m';
    if (h > 0) return '${h}h';
    return '${r}m';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Park Visit History'),
        backgroundColor: const Color(0xFF567D46),
        elevation: 2,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF567D46), Color(0xFF365A38)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: user == null
            ? const Center(
                child: Text('Please sign in.',
                    style: TextStyle(color: Colors.white)),
              )
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('owners')
                    .doc(user.uid)
                    .collection('visit_history')
                    .orderBy('checkInAt', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Text('Error: ${snap.error}',
                          style: const TextStyle(color: Colors.white)),
                    );
                  }
                  final docs = snap.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        'No visits yet.',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    );
                  }

                  // Group by day string if present; otherwise by date(checkInAt)
                  final Map<String,
                          List<QueryDocumentSnapshot<Map<String, dynamic>>>>
                      groups = {};
                  for (final d in docs) {
                    final data = d.data();
                    final dayStr = (data['day'] as String?)?.trim();
                    if (dayStr != null && dayStr.isNotEmpty) {
                      groups.putIfAbsent(dayStr, () => []).add(d);
                    } else {
                      final ts = data['checkInAt'] as Timestamp?;
                      final dt = ts?.toDate();
                      final key = (dt == null)
                          ? 'Unknown'
                          : DateFormat('yyyy-MM-dd').format(dt.toLocal());
                      groups.putIfAbsent(key, () => []).add(d);
                    }
                  }

                  // Sort groups by date desc; push "Unknown" to bottom
                  final keys = groups.keys.toList()
                    ..sort((a, b) {
                      if (a == 'Unknown') return 1;
                      if (b == 'Unknown') return -1;
                      return b.compareTo(a); // yyyy-mm-dd desc
                    });

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: keys.length,
                    itemBuilder: (_, i) {
                      final key = keys[i];
                      final items = groups[key]!;
                      // Pretty date header
                      String header;
                      if (key == 'Unknown') {
                        header = 'Unknown date';
                      } else {
                        final dt = DateTime.tryParse(key);
                        if (dt == null) {
                          header = key;
                        } else {
                          final today = DateTime.now();
                          final d0 =
                              DateTime(today.year, today.month, today.day);
                          final dk = DateTime(dt.year, dt.month, dt.day);
                          if (dk == d0) {
                            header = 'Today';
                          } else if (dk ==
                              d0.subtract(const Duration(days: 1))) {
                            header = 'Yesterday';
                          } else {
                            header = DateFormat('EEE, MMM d, yyyy').format(dt);
                          }
                        }
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // header
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 4, bottom: 6, top: 8),
                            child: Text(
                              header,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          ...items.map((d) {
                            final data = d.data();
                            final parkName =
                                (data['parkName'] as String?)?.trim();
                            final checkInAt = data['checkInAt'] as Timestamp?;
                            final checkOutAt = data['checkOutAt'] as Timestamp?;
                            final durationMin = data['durationMinutes'] as num?;
                            final active = checkOutAt == null;

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Material(
                                color: Colors.transparent,
                                child: Ink(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.92),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.black.withOpacity(0.06),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.12),
                                        blurRadius: 16,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    leading: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF567D46),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(Icons.park,
                                          color: Colors.white, size: 26),
                                    ),
                                    title: Text(
                                      parkName?.isNotEmpty == true
                                          ? parkName!
                                          : 'This park',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        _fmtRange(checkInAt, checkOutAt),
                                        style: TextStyle(
                                            color:
                                                Colors.black.withOpacity(0.75)),
                                      ),
                                    ),
                                    trailing: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: active
                                            ? Colors.orange.withOpacity(0.15)
                                            : Colors.black.withOpacity(0.06),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        active
                                            ? 'Active'
                                            : _fmtDuration(durationMin),
                                        style: TextStyle(
                                          color: active
                                              ? Colors.orange.shade700
                                              : Colors.black87,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}
