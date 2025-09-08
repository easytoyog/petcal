import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:image_picker/image_picker.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:inthepark/models/service_ad_model.dart';
import 'package:inthepark/utils/image_upload_util.dart';
import 'package:location/location.dart' as loc;
import 'package:url_launcher/url_launcher.dart';

class ServiceTab extends StatefulWidget {
  const ServiceTab({super.key});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<ServiceTab> {
  final _types = const [
    'All',
    'Walker',
    'Groomer',
    'Daycare',
    'Lost Dog',
    'Trainer',
    'Other',
  ];

  String _selectedType = 'All';
  List<ServiceAd> _ads = [];
  double? userLat;
  double? userLng;
  bool _isLoading = true;

  final _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _loadLocationAndAds();
  }

  Future<void> _loadLocationAndAds() async {
    setState(() => _isLoading = true);
    try {
      final location = loc.Location();
      final locData = await location.getLocation();
      userLat = locData.latitude;
      userLng = locData.longitude;
    } catch (_) {
      // ignore location failures; still load ads
    }
    await _fetchAds();
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    // Haversine
    const p = 0.017453292519943295;
    double c(double x) => math.cos(x);
    final a = 0.5 -
        c((lat2 - lat1) * p) / 2 +
        c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a));
  }

  Future<void> _fetchAds() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await _firestore
          .collection('services')
          .orderBy('createdAt', descending: true)
          .get();

      final ads = snapshot.docs.map((doc) => ServiceAd.fromFirestore(doc)).toList();

      for (var ad in ads) {
        if (userLat != null && userLng != null) {
          ad.distanceFromUser =
              _calculateDistance(userLat!, userLng!, ad.latitude, ad.longitude);
        }
      }

      if (!mounted) return;
      setState(() {
        _ads = ads;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load services: $e')),
      );
    }
  }

  Future<void> _openPostScreen({ServiceAd? existingAd}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You must be signed in to post.')),
      );
      return;
    }

    String? prefillPostalCode;
    if (existingAd == null) {
      try {
        final ownerDoc = await _firestore.collection('owners').doc(user.uid).get();
        if (ownerDoc.exists) {
          final owner = Owner.fromFirestore(ownerDoc);
          prefillPostalCode = owner.address.postalCode;
        }
      } catch (_) {}
    }

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PostServiceScreen(
          types: _types,
          existingAd: existingAd,
          prefillPostalCode: prefillPostalCode,
          userLat: userLat,
          userLng: userLng,
        ),
      ),
    );

    if (result == true && mounted) {
      await _fetchAds();
    }
  }

  void _openServiceDetails(ServiceAd ad) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isOwner = currentUser != null && ad.ownerId == currentUser.uid;
    final pageController = PageController();
    int currentPage = 0;
    bool isLoadingOwner = true;
    Owner? adOwner;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          if (isLoadingOwner) {
            FirebaseFirestore.instance
                .collection('owners')
                .doc(ad.ownerId)
                .get()
                .then((ownerDoc) {
              setState(() {
                adOwner = ownerDoc.exists ? Owner.fromFirestore(ownerDoc) : null;
                isLoadingOwner = false;
              });
            }).catchError((_) {
              setState(() => isLoadingOwner = false);
            });
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  title: Text(ad.title),
                  backgroundColor: Colors.green,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                  ),
                  actions: [
                    if (isOwner)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _openPostScreen(existingAd: ad);
                        },
                      ),
                    if (isOwner)
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: ctx,
                            builder: (c) => AlertDialog(
                              title: const Text('Delete Service'),
                              content:
                                  const Text('Are you sure you want to delete this service?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(c).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(c).pop(true),
                                  child: const Text('Delete',
                                      style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );

                          if (confirm == true) {
                            try {
                              Navigator.of(ctx).pop();
                              await FirebaseFirestore.instance
                                  .collection('services')
                                  .doc(ad.id)
                                  .delete();
                              await _fetchAds();
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Service deleted successfully!'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Couldn\'t delete: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                      ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (ad.images.isNotEmpty)
                            Stack(
                              children: [
                                SizedBox(
                                  height: 200,
                                  child: PageView.builder(
                                    controller: pageController,
                                    itemCount: ad.images.length,
                                    onPageChanged: (index) {
                                      setState(() => currentPage = index);
                                    },
                                    itemBuilder: (context, index) {
                                      return GestureDetector(
                                        onTap: () => _showFullImage(context, ad.images[index]),
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.symmetric(horizontal: 4),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: Image.network(
                                              ad.images[index],
                                              fit: BoxFit.cover,
                                              loadingBuilder: (context, child, prog) {
                                                if (prog == null) return child;
                                                return Center(
                                                  child: CircularProgressIndicator(
                                                    value:
                                                        (prog.expectedTotalBytes != null)
                                                            ? prog.cumulativeBytesLoaded /
                                                                prog.expectedTotalBytes!
                                                            : null,
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (ad.images.length > 1)
                                  Positioned.fill(
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        _pagerButton(
                                          enabled: currentPage > 0,
                                          icon: Icons.arrow_back_ios,
                                          onTap: () => pageController.previousPage(
                                            duration:
                                                const Duration(milliseconds: 300),
                                            curve: Curves.easeInOut,
                                          ),
                                        ),
                                        _pagerButton(
                                          enabled: currentPage < ad.images.length - 1,
                                          icon: Icons.arrow_forward_ios,
                                          onTap: () => pageController.nextPage(
                                            duration:
                                                const Duration(milliseconds: 300),
                                            curve: Curves.easeInOut,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          if (ad.images.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(
                                  ad.images.length,
                                  (index) => Container(
                                    margin:
                                        const EdgeInsets.symmetric(horizontal: 4),
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: currentPage == index
                                          ? Colors.green
                                          : Colors.grey[300],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          Text(
                            ad.type,
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(ad.description,
                              style: const TextStyle(fontSize: 16)),
                          const SizedBox(height: 12),
                          if (ad.distanceFromUser != null)
                            Text(
                              'Distance: ${ad.distanceFromUser!.toStringAsFixed(1)} km',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          const SizedBox(height: 20),
                          const Divider(),
                          const Text(
                            'Contact Information',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          isLoadingOwner
                              ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : adOwner != null
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.person,
                                                size: 20, color: Colors.green),
                                            const SizedBox(width: 8),
                                            Text(
                                              '${adOwner!.firstName} ${adOwner!.lastName}',
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        InkWell(
                                          onTap: () async {
                                            final uri =
                                                Uri(scheme: 'tel', path: adOwner!.phone);
                                            if (await canLaunchUrl(uri)) {
                                              await launchUrl(uri);
                                            }
                                          },
                                          child: Row(
                                            children: [
                                              const Icon(Icons.phone,
                                                  size: 20, color: Colors.green),
                                              const SizedBox(width: 8),
                                              Text(
                                                adOwner!.phone,
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  color: Colors.blue,
                                                  decoration:
                                                      TextDecoration.underline,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        InkWell(
                                          onTap: () async {
                                            final uri = Uri(
                                              scheme: 'mailto',
                                              path: adOwner!.email,
                                            );
                                            if (await canLaunchUrl(uri)) {
                                              await launchUrl(uri);
                                            }
                                          },
                                          child: Row(
                                            children: [
                                              const Icon(Icons.email,
                                                  size: 20, color: Colors.green),
                                              const SizedBox(width: 8),
                                              Text(
                                                adOwner!.email,
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  color: Colors.blue,
                                                  decoration:
                                                      TextDecoration.underline,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  : const Text(
                                      'Contact information not available',
                                      style: TextStyle(
                                        fontStyle: FontStyle.italic,
                                        color: Colors.grey,
                                      ),
                                    ),
                          const SizedBox(height: 20),
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 40),
                            ),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _pagerButton({
    required bool enabled,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: enabled ? Colors.black26 : Colors.black12,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: enabled ? Colors.white : Colors.white54,
          size: 20,
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: Image.network(
                imageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, prog) {
                  if (prog == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      value: (prog.expectedTotalBytes != null)
                          ? prog.cumulativeBytesLoaded /
                              prog.expectedTotalBytes!
                          : null,
                    ),
                  );
                },
              ),
            ),
            IconButton(
              icon: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white),
              ),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdCard(ServiceAd ad) {
    final user = FirebaseAuth.instance.currentUser;
    final isOwner = user != null && ad.ownerId == user.uid;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: InkWell(
        onTap: () => _openServiceDetails(ad),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ad.images.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    ad.images.first,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, prog) {
                      if (prog == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: (prog.expectedTotalBytes != null)
                              ? prog.cumulativeBytesLoaded /
                                  prog.expectedTotalBytes!
                              : null,
                        ),
                      );
                    },
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          ad.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isOwner)
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _openPostScreen(existingAd: ad),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('Delete Service'),
                                    content: const Text(
                                      'Are you sure you want to delete this service?',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(c).pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.of(c).pop(true),
                                        child: const Text('Delete',
                                            style: TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirm == true) {
                                  try {
                                    await FirebaseFirestore.instance
                                        .collection('services')
                                        .doc(ad.id)
                                        .delete();
                                    await _fetchAds();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Service deleted successfully!'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  } catch (e) {
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Couldn\'t delete: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ad.type,
                    style: TextStyle(
                      color: Colors.grey[700],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ad.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  if (ad.distanceFromUser != null)
                    Row(
                      children: [
                        const Icon(Icons.location_on, size: 16, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          '${ad.distanceFromUser!.toStringAsFixed(1)} km away',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                        const Spacer(),
                        if (ad.images.length > 1)
                          Row(
                            children: [
                              const Icon(Icons.photo_library,
                                  size: 16, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(
                                '${ad.images.length} photos',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredAds =
        _selectedType == 'All' ? _ads : _ads.where((ad) => ad.type == _selectedType).toList();

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: _types.map((type) {
                  final isSelected = _selectedType == type;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(type),
                      selected: isSelected,
                      onSelected: (selected) {
                        if (selected) setState(() => _selectedType = type);
                      },
                      backgroundColor: Colors.grey[200],
                      selectedColor: Colors.green[100],
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.green[800] : Colors.black,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredAds.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'No services found${_selectedType != 'All' ? ' for $_selectedType' : ''}',
                              style: TextStyle(color: Colors.grey[600], fontSize: 16),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchAds,
                        child: ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 80),
                          itemCount: filteredAds.length,
                          itemBuilder: (context, index) => _buildAdCard(filteredAds[index]),
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openPostScreen(),
        backgroundColor: Colors.green,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// =======================
/// Full-screen Post Screen
/// =======================
class _PostServiceScreen extends StatefulWidget {
  final List<String> types;
  final ServiceAd? existingAd;
  final String? prefillPostalCode;
  final double? userLat;
  final double? userLng;

  const _PostServiceScreen({
    required this.types,
    this.existingAd,
    this.prefillPostalCode,
    this.userLat,
    this.userLng,
  });

  @override
  State<_PostServiceScreen> createState() => _PostServiceScreenState();
}

class _PostServiceScreenState extends State<_PostServiceScreen> {
  final _firestore = FirebaseFirestore.instance;

  late final TextEditingController titleCtl;
  late final TextEditingController descCtl;
  late final TextEditingController postalCtl;
  final FocusNode titleFocusNode = FocusNode();

  late String dialogType;
  final List<XFile> _pickedImages = [];
  final List<String> _existingImageUrls = [];

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    titleCtl = TextEditingController(text: widget.existingAd?.title);
    descCtl = TextEditingController(text: widget.existingAd?.description);
    postalCtl = TextEditingController(
      text: widget.existingAd?.postalCode ?? widget.prefillPostalCode ?? '',
    );
    dialogType = widget.existingAd?.type ?? widget.types[1];

    if (widget.existingAd != null && widget.existingAd!.images.isNotEmpty) {
      _existingImageUrls.addAll(widget.existingAd!.images);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    titleCtl.dispose();
    descCtl.dispose();
    postalCtl.dispose();
    titleFocusNode.dispose();
    super.dispose();
  }

  InputDecoration _bordered(String label) {
    const green = Colors.green;
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(width: 1.2, color: Color(0xFFBDBDBD)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(width: 1.8, color: green),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    final images = await picker.pickMultiImage();
    setState(() {
      final remaining = 5 - (_existingImageUrls.length + _pickedImages.length);
      if (remaining > 0) {
        _pickedImages.addAll(images.take(remaining));
      }
    });
  }

  Future<void> _save() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    setState(() => _saving = true);

    try {
      // Upload any new images via utility (compressed JPEGs)
      final allImages = [..._existingImageUrls];
      for (final x in _pickedImages) {
        final url = await ImageUploadUtil.uploadServiceImageFromXFile(
          x,
          maxSide: 1600,
          quality: 80,
        );
        allImages.add(url);
      }

      // Geocode postal code (optional)
      String postal = postalCtl.text.trim();
      double? geoLat = widget.userLat;
      double? geoLng = widget.userLng;

      if (postal.isNotEmpty) {
        try {
          final locations = await geocoding.locationFromAddress(postal);
          if (locations.isNotEmpty) {
            geoLat = locations.first.latitude;
            geoLng = locations.first.longitude;
          }
        } catch (_) {
          // ignore geocoding failures
        }
      }

      final data = <String, dynamic>{
        'ownerId': current.uid,
        'title': titleCtl.text.trim(),
        'description': descCtl.text.trim(),
        'type': dialogType,
        'latitude': geoLat ?? 0.0,
        'longitude': geoLng ?? 0.0,
        'images': allImages,
        'postalCode': postal,
        'price': null,      // keep schema happy
        'approved': false,  // explicit bool per rules
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.existingAd == null) {
        data['createdAt'] = FieldValue.serverTimestamp();
        await _firestore.collection('services').add(data);
      } else {
        await _firestore.collection('services').doc(widget.existingAd!.id).update(data);
      }

      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.existingAd == null
              ? 'Service posted successfully!'
              : 'Service updated successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.existingAd == null ? 'Post New Service' : 'Save Changes';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.green,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save', style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: titleCtl,
                  focusNode: titleFocusNode,
                  decoration: _bordered('Title'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtl,
                  maxLines: 4,
                  decoration: _bordered('Description'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: dialogType,
                  items: widget.types
                      .skip(1)
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => dialogType = val);
                  },
                  decoration: _bordered('Type'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: postalCtl,
                  decoration: _bordered('Postal Code'),
                ),
                const SizedBox(height: 16),

                // Images header + add
                Row(
                  children: [
                    Text(
                      'Images (${_existingImageUrls.length + _pickedImages.length}/5)',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: _existingImageUrls.length + _pickedImages.length < 5
                          ? _pickImages
                          : null,
                      icon: const Icon(Icons.add_photo_alternate),
                      label: const Text('Add Images'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Existing images
                if (_existingImageUrls.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Existing Images:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _existingImageUrls.map((url) {
                            return Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.network(
                                    url,
                                    width: 90,
                                    height: 90,
                                    fit: BoxFit.cover,
                                    loadingBuilder: (context, child, prog) {
                                      if (prog == null) return child;
                                      return Container(
                                        width: 90,
                                        height: 90,
                                        color: Colors.grey[300],
                                        child: const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: GestureDetector(
                                    onTap: () => setState(
                                        () => _existingImageUrls.remove(url)),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.15),
                                            blurRadius: 6,
                                          )
                                        ],
                                      ),
                                      padding: const EdgeInsets.all(2),
                                      child: const Icon(Icons.close,
                                          color: Colors.red, size: 18),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),

                // New images
                if (_pickedImages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('New Images:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _pickedImages.map((img) {
                            return Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.file(
                                    File(img.path),
                                    width: 90,
                                    height: 90,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: GestureDetector(
                                    onTap: () => setState(() => _pickedImages.remove(img)),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.15),
                                            blurRadius: 6,
                                          )
                                        ],
                                      ),
                                      padding: const EdgeInsets.all(2),
                                      child: const Icon(Icons.close,
                                          color: Colors.red, size: 18),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 24),

                // Post button with spinner next to it
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.check),
                        label: Text(
                          widget.existingAd == null ? 'Post Service' : 'Save Changes',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_saving)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),

                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
