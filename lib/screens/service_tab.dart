import 'dart:io';
import 'dart:math' as Math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:location/location.dart' as loc;
import 'package:inthepark/models/service_ad_model.dart';
import 'package:inthepark/models/owner_model.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geocoding/geocoding.dart';

class ServiceTab extends StatefulWidget {
  const ServiceTab({super.key});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<ServiceTab> {
  final _types = [
    'All',
    'Dog Walker',
    'Groomer',
    'Daycare',
    'Lost Dog',
    'Other'
  ];
  String _selectedType = 'All';
  List<ServiceAd> _ads = [];
  double? userLat;
  double? userLng;
  bool _isLoading = true;
  final _firestore = FirebaseFirestore.instance;
  final List<XFile> _pickedImages = [];
  final List<String> _existingImageUrls = [];

  @override
  void initState() {
    super.initState();
    _loadLocationAndAds();
  }

  Future<void> _loadLocationAndAds() async {
    setState(() => _isLoading = true);
    final location = loc.Location();
    final locData = await location.getLocation();
    userLat = locData.latitude;
    userLng = locData.longitude;
    await _fetchAds();
  }

  double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    c(double x) => Math.cos(x);
    final a = 0.5 -
        c((lat2 - lat1) * p) / 2 +
        c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * Math.asin(Math.sqrt(a));
  }

  Future<void> _fetchAds() async {
    setState(() => _isLoading = true);
    final snapshot = await _firestore
        .collection('services')
        .orderBy('createdAt', descending: true)
        .get();
    final ads =
        snapshot.docs.map((doc) => ServiceAd.fromFirestore(doc)).toList();
    for (var ad in ads) {
      if (userLat != null && userLng != null) {
        ad.distanceFromUser =
            _calculateDistance(userLat!, userLng!, ad.latitude, ad.longitude);
      }
    }
    setState(() {
      _ads = ads;
      _isLoading = false;
    });
  }

  Future<void> _pickImages(StateSetter setSt) async {
    final picker = ImagePicker();
    final images = await picker.pickMultiImage();
    setSt(() {
      int remainingSlots = 5 - _existingImageUrls.length;
      if (remainingSlots > 0) {
        _pickedImages.addAll(images.take(remainingSlots));
      }
    });
  }

  Future<void> _openPostDialog([ServiceAd? existingAd]) async {
    _pickedImages.clear();
    _existingImageUrls.clear();

    final user = FirebaseAuth.instance.currentUser;
    String? prefillPostalCode;

    // Fetch user's postal code if not editing an existing ad
    if (existingAd == null && user != null) {
      final ownerDoc =
          await _firestore.collection('owners').doc(user.uid).get();
      if (ownerDoc.exists) {
        final owner = Owner.fromFirestore(ownerDoc);
        prefillPostalCode = owner.address.postalCode;
      }
    }

    final titleCtl = TextEditingController(text: existingAd?.title);
    final descCtl = TextEditingController(text: existingAd?.description);
    final postalCtl = TextEditingController(
      text: existingAd?.postalCode ?? prefillPostalCode ?? '',
    );
    final titleFocusNode = FocusNode();
    String dialogType = existingAd?.type ?? _types[1];

    if (existingAd != null && existingAd.images.isNotEmpty) {
      _existingImageUrls.addAll(existingAd.images);
    }

    WidgetsBinding.instance
        .addPostFrameCallback((_) => titleFocusNode.requestFocus());

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(existingAd == null ? Icons.post_add : Icons.edit,
                      color: Colors.green),
                  const SizedBox(width: 8),
                  Text(
                      existingAd == null ? 'Post New Service' : 'Edit Service'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtl,
                      focusNode: titleFocusNode,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: dialogType,
                      items: _types
                          .skip(1)
                          .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) setSt(() => dialogType = val);
                      },
                      decoration: const InputDecoration(
                        labelText: 'Type',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: postalCtl,
                      decoration: const InputDecoration(
                        labelText: 'Postal Code',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                            "Images (${_existingImageUrls.length + _pickedImages.length}/5)"),
                        const Spacer(),
                        OutlinedButton(
                          onPressed:
                              _existingImageUrls.length + _pickedImages.length <
                                      5
                                  ? () => _pickImages(setSt)
                                  : null,
                          child: const Text('Add Images'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_existingImageUrls.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Existing Images:",
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: _existingImageUrls.map((url) {
                                return Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        url,
                                        width: 80,
                                        height: 80,
                                        fit: BoxFit.cover,
                                        loadingBuilder:
                                            (context, child, loadingProgress) {
                                          if (loadingProgress == null) {
                                            return child;
                                          }
                                          return Container(
                                            width: 80,
                                            height: 80,
                                            color: Colors.grey[300],
                                            child: const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: GestureDetector(
                                        onTap: () {
                                          setSt(() =>
                                              _existingImageUrls.remove(url));
                                        },
                                        child: Container(
                                          decoration: const BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.cancel,
                                              color: Colors.red, size: 22),
                                        ),
                                      ),
                                    )
                                  ],
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    if (_pickedImages.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("New Images:",
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: _pickedImages.map((img) {
                                return Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        File(img.path),
                                        width: 80,
                                        height: 80,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: GestureDetector(
                                        onTap: () {
                                          setSt(
                                              () => _pickedImages.remove(img));
                                        },
                                        child: Container(
                                          decoration: const BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.cancel,
                                              color: Colors.red, size: 22),
                                        ),
                                      ),
                                    )
                                  ],
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) return;

                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (ctx) =>
                          const Center(child: CircularProgressIndicator()),
                    );

                    try {
                      List<String> allImages = [..._existingImageUrls];
                      for (var img in _pickedImages) {
                        final file = File(img.path);
                        final ref = FirebaseStorage.instance.ref(
                            'service_images/${DateTime.now().millisecondsSinceEpoch}_${allImages.length}');
                        await ref.putFile(file);
                        final url = await ref.getDownloadURL();
                        allImages.add(url);
                      }

                      // Geocode postal code
                      String postal = postalCtl.text.trim();
                      double? geoLat = userLat;
                      double? geoLng = userLng;
                      if (postal.isNotEmpty) {
                        try {
                          List<Location> locations =
                              await locationFromAddress(postal);
                          if (locations.isNotEmpty) {
                            geoLat = locations.first.latitude;
                            geoLng = locations.first.longitude;
                          }
                        } catch (e) {
                          // Optionally show a warning if geocoding fails
                          print('Postal code geocoding failed: $e');
                        }
                      }

                      final data = {
                        'title': titleCtl.text.trim(),
                        'description': descCtl.text.trim(),
                        'type': dialogType,
                        'userId': user.uid,
                        'latitude':
                            geoLat ?? 0.0, // <-- Ensure double, not null
                        'longitude':
                            geoLng ?? 0.0, // <-- Ensure double, not null
                        'images': allImages,
                        'postalCode': postal,
                      };

                      if (existingAd == null) {
                        data['createdAt'] = FieldValue.serverTimestamp();
                        await _firestore.collection('services').add(data);
                      } else {
                        data['updatedAt'] = FieldValue.serverTimestamp();
                        await _firestore
                            .collection('services')
                            .doc(existingAd.id)
                            .update(data);
                      }

                      await _fetchAds();

                      Navigator.of(context).pop();
                      Navigator.of(ctx).pop();

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(existingAd == null
                              ? 'Service posted successfully!'
                              : 'Service updated successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } catch (e) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error: ${e.toString()}'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: Text(existingAd == null ? 'Post' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openServiceDetails(ServiceAd ad) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isOwner = currentUser != null && ad.userId == currentUser.uid;
    final PageController pageController = PageController();
    int currentPage = 0;
    bool isLoadingOwner = true;
    Owner? adOwner;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          if (isLoadingOwner) {
            _firestore
                .collection('owners')
                .doc(ad.userId)
                .get()
                .then((ownerDoc) {
              if (ownerDoc.exists) {
                setState(() {
                  adOwner = Owner.fromFirestore(ownerDoc);
                  isLoadingOwner = false;
                });
              } else {
                setState(() {
                  isLoadingOwner = false;
                });
              }
            }).catchError((error) {
              setState(() {
                isLoadingOwner = false;
              });
            });
          }

          return Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                          _openPostDialog(ad);
                        },
                      ),
                    if (isOwner)
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Delete Service'),
                              content: const Text(
                                  'Are you sure you want to delete this service?'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('Delete',
                                      style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );

                          if (confirm == true) {
                            Navigator.of(ctx).pop();
                            await _firestore
                                .collection('services')
                                .doc(ad.id)
                                .delete();
                            await _fetchAds();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Service deleted successfully!'),
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
                                      setState(() {
                                        currentPage = index;
                                      });
                                    },
                                    itemBuilder: (context, index) {
                                      return GestureDetector(
                                        onTap: () => _showFullImage(
                                            context, ad.images[index]),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.network(
                                              ad.images[index],
                                              fit: BoxFit.cover,
                                              loadingBuilder: (context, child,
                                                  loadingProgress) {
                                                if (loadingProgress == null) {
                                                  return child;
                                                }
                                                return Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                    value: loadingProgress
                                                                .expectedTotalBytes !=
                                                            null
                                                        ? loadingProgress
                                                                .cumulativeBytesLoaded /
                                                            loadingProgress
                                                                .expectedTotalBytes!
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
                                        GestureDetector(
                                          onTap: currentPage > 0
                                              ? () {
                                                  pageController.previousPage(
                                                    duration: const Duration(
                                                        milliseconds: 300),
                                                    curve: Curves.easeInOut,
                                                  );
                                                }
                                              : null,
                                          child: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: currentPage > 0
                                                  ? Colors.black26
                                                  : Colors.black12,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.arrow_back_ios,
                                              color: currentPage > 0
                                                  ? Colors.white
                                                  : Colors.white54,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap: currentPage <
                                                  ad.images.length - 1
                                              ? () {
                                                  pageController.nextPage(
                                                    duration: const Duration(
                                                        milliseconds: 300),
                                                    curve: Curves.easeInOut,
                                                  );
                                                }
                                              : null,
                                          child: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: currentPage <
                                                      ad.images.length - 1
                                                  ? Colors.black26
                                                  : Colors.black12,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.arrow_forward_ios,
                                              color: currentPage <
                                                      ad.images.length - 1
                                                  ? Colors.white
                                                  : Colors.white54,
                                              size: 20,
                                            ),
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
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 4),
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
                          Text(
                            ad.description,
                            style: const TextStyle(fontSize: 16),
                          ),
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
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
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
                                            final url = 'tel:${adOwner!.phone}';
                                            if (await canLaunch(url)) {
                                              await launch(url);
                                            }
                                          },
                                          child: Row(
                                            children: [
                                              const Icon(Icons.phone,
                                                  size: 20,
                                                  color: Colors.green),
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
                                            final url =
                                                'mailto:${adOwner!.email}';
                                            if (await canLaunch(url)) {
                                              await launch(url);
                                            }
                                          },
                                          child: Row(
                                            children: [
                                              const Icon(Icons.email,
                                                  size: 20,
                                                  color: Colors.green),
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
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      value: loadingProgress.expectedTotalBytes != null
                          ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
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
    final isOwner = user != null && ad.userId == user.uid;

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
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!
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
                              onPressed: () => _openPostDialog(ad),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Delete Service'),
                                    content: const Text(
                                        'Are you sure you want to delete this service?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(true),
                                        child: const Text('Delete',
                                            style:
                                                TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirm == true) {
                                  await _firestore
                                      .collection('services')
                                      .doc(ad.id)
                                      .delete();
                                  await _fetchAds();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Service deleted successfully!'),
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
                        const Icon(Icons.location_on,
                            size: 16, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          '${ad.distanceFromUser!.toStringAsFixed(1)} km away',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
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
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
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
    final filteredAds = _selectedType == 'All'
        ? _ads
        : _ads.where((ad) => ad.type == _selectedType).toList();

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
                        if (selected) {
                          setState(() => _selectedType = type);
                        }
                      },
                      backgroundColor: Colors.grey[200],
                      selectedColor: Colors.green[100],
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.green[800] : Colors.black,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
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
                            Icon(Icons.search_off,
                                size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'No services found${_selectedType != 'All' ? ' for $_selectedType' : ''}',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 16),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchAds,
                        child: ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 80),
                          itemCount: filteredAds.length,
                          itemBuilder: (context, index) =>
                              _buildAdCard(filteredAds[index]),
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openPostDialog(),
        backgroundColor: Colors.green,
        child: const Icon(Icons.add),
      ),
    );
  }
}
