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
import 'package:profanity_filter/profanity_filter.dart';

class ServiceTab extends StatefulWidget {
  const ServiceTab({super.key});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class ReportsService {
  final _db = FirebaseFirestore.instance;
  String? get _me => FirebaseAuth.instance.currentUser?.uid;

  Future<void> submitServiceReport({
    required String serviceId,
    required String serviceOwnerId,
    required String serviceTitle,
    required String serviceType,
    String? serviceDescription,
    required String reason,
    String? notes,
  }) async {
    final me = _me;
    if (me == null || serviceOwnerId.isEmpty) return;

    await _db.collection('moderation_reports').add({
      'type': 'service',
      'reporterId': me,
      'reportedUserId': serviceOwnerId,
      'serviceId': serviceId,
      'serviceTitle': serviceTitle,
      'serviceType': serviceType,
      'serviceDescription': serviceDescription ?? '',
      'reason': reason,
      'notes': notes ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<Set<String>> fetchMyReportedServiceIds() async {
    final me = _me;
    if (me == null) return <String>{};
    final q = await _db
        .collection('moderation_reports')
        .where('type', isEqualTo: 'service')
        .where('reporterId', isEqualTo: me)
        .get();
    return q.docs
        .map((d) => (d.data()['serviceId'] ?? '') as String)
        .where((id) => id.isNotEmpty)
        .toSet();
  }
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

  bool _showOnlyMine = false;

  final _firestore = FirebaseFirestore.instance;
  final _reports = ReportsService();

  Set<String> _myReportedServiceIds = <String>{};

  final ProfanityFilter _filter = ProfanityFilter();

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
    } catch (_) {}
    await _fetchAds();
    await _refreshMyReportedServices();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _refreshMyReportedServices() async {
    final set = await _reports.fetchMyReportedServiceIds();
    if (mounted) setState(() => _myReportedServiceIds = set);
  }

  Future<void> _reportServiceDialog(ServiceAd ad) async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == ad.ownerId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You can’t report your own service.")),
      );
      return;
    }
    if (_myReportedServiceIds.contains(ad.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You already flagged this service.')),
      );
      return;
    }

    final reasons = <String>[
      'Spam',
      'Harassment or bullying',
      'Hate speech',
      'Explicit content',
      'Scam or fraud',
      'Other',
    ];
    String selected = reasons.first;
    final notesCtl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report service'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: selected,
              items: reasons
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => selected = v ?? reasons.first,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtl,
              decoration: const InputDecoration(
                labelText: 'Additional details (optional)',
                hintText: 'Add context for moderators…',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          FilledButton(
            child: const Text('Submit'),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (ok == true) {
      try {
        await _reports.submitServiceReport(
          serviceId: ad.id,
          serviceOwnerId: ad.ownerId,
          serviceTitle: ad.title,
          serviceType: ad.type,
          serviceDescription: ad.description,
          reason: selected,
          notes: notesCtl.text.trim(),
        );
        if (mounted) {
          setState(() {
            _myReportedServiceIds.add(ad.id);
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted. Thank you.')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit report: $e')),
        );
      }
    }
  }

  double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    double c(double x) => math.cos(x);
    final a = 0.5 -
        c((lat2 - lat1) * p) / 2 +
        c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a));
  }

  Future<void> _fetchAds() async {
    try {
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

      if (!mounted) return;
      setState(() => _ads = ads);
    } catch (e) {
      if (!mounted) return;
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
        final ownerDoc =
            await _firestore.collection('owners').doc(user.uid).get();
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

  Future<void> _openServiceDetailsFullScreen(ServiceAd ad) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServiceDetailsScreen(
          ad: ad,
          initiallyReported: _myReportedServiceIds.contains(ad.id),
          onReportSubmitted: () {
            setState(() => _myReportedServiceIds.add(ad.id));
          },
          onEditRequested: () => _openPostScreen(existingAd: ad),
          onDeleted: () async {
            await _fetchAds();
          },
        ),
      ),
    );
  }

  Widget _buildAdCard(ServiceAd ad) {
    final user = FirebaseAuth.instance.currentUser;
    final isOwner = user != null && ad.ownerId == user.uid;
    final isReported = _myReportedServiceIds.contains(ad.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: InkWell(
        onTap: () => _openServiceDetailsFullScreen(ad),
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
                    children: [
                      Expanded(
                        child: Text(
                          ad.title,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                      // flag only for non-owners
                      if (!isOwner)
                        IconButton(
                          tooltip: isReported
                              ? 'You flagged this'
                              : 'Report this service',
                          icon: Icon(
                            isReported ? Icons.flag : Icons.flag_outlined,
                            color: isReported ? Colors.red : Colors.grey[700],
                          ),
                          onPressed: isReported
                              ? null
                              : () => _reportServiceDialog(ad),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),

                      const SizedBox(width: 4),

                      if (isOwner)
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () => _openPostScreen(existingAd: ad),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      if (isOwner) const SizedBox(width: 8),
                      if (isOwner)
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
                                    content:
                                        Text('Service deleted successfully!'),
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

  void _onTapMyPostsQuickFilter() {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to view your posts.')),
      );
      return;
    }

    final myCount = _ads.where((a) => a.ownerId == current.uid).length;
    if (myCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You haven't created any services yet")),
      );
      return;
    }

    setState(() => _showOnlyMine = !_showOnlyMine);
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;

    List<ServiceAd> filteredAds = _selectedType == 'All'
        ? _ads
        : _ads.where((ad) => ad.type == _selectedType).toList();

    if (_showOnlyMine && current != null) {
      filteredAds =
          filteredAds.where((ad) => ad.ownerId == current.uid).toList();
    }

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
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          if (_showOnlyMine)
            Container(
              width: double.infinity,
              color: Colors.green.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Text(
                'Showing only your services',
                style:
                    TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
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
                              'No services found'
                              '${_selectedType != 'All' ? ' for $_selectedType' : ''}'
                              '${_showOnlyMine ? ' (your posts)' : ''}',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 16),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _fetchAds();
                          await _refreshMyReportedServices();
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 120),
                          itemCount: filteredAds.length,
                          itemBuilder: (context, index) =>
                              _buildAdCard(filteredAds[index]),
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'fab_my_posts',
            onPressed: _onTapMyPostsQuickFilter,
            backgroundColor: _showOnlyMine
                ? const Color(0xFF2E7D32)
                : const Color(0xFF66BB6A),
            icon: const Icon(Icons.filter_list, color: Colors.white),
            label:
                const Text('My posts', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'fab_add',
            onPressed: () => _openPostScreen(),
            backgroundColor: Colors.green,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// =======================
/// Full-screen Service Details
/// =======================
class ServiceDetailsScreen extends StatefulWidget {
  final ServiceAd ad;
  final bool initiallyReported;
  final VoidCallback onReportSubmitted;
  final VoidCallback onEditRequested;
  final Future<void> Function() onDeleted;

  const ServiceDetailsScreen({
    super.key,
    required this.ad,
    required this.initiallyReported,
    required this.onReportSubmitted,
    required this.onEditRequested,
    required this.onDeleted,
  });

  @override
  State<ServiceDetailsScreen> createState() => _ServiceDetailsScreenState();
}

class _ServiceDetailsScreenState extends State<ServiceDetailsScreen> {
  final _reports = ReportsService();

  int _currentPage = 0;
  bool _isLoadingOwner = true;
  Owner? _owner;
  late bool _isReportedByMe;

  @override
  void initState() {
    super.initState();
    _isReportedByMe = widget.initiallyReported;
    _loadOwner();
  }

  Future<void> _loadOwner() async {
    try {
      final ownerDoc = await FirebaseFirestore.instance
          .collection('owners')
          .doc(widget.ad.ownerId)
          .get();
      if (!mounted) return;
      setState(() {
        _owner = ownerDoc.exists ? Owner.fromFirestore(ownerDoc) : null;
        _isLoadingOwner = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingOwner = false);
    }
  }

  Future<void> _deleteService() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete Service'),
        content: const Text('Are you sure you want to delete this service?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await FirebaseFirestore.instance
            .collection('services')
            .doc(widget.ad.id)
            .delete();
        if (!mounted) return;
        await widget.onDeleted();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Service deleted successfully!'),
            backgroundColor: Colors.red,
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t delete: $e')),
        );
      }
    }
  }

  Future<void> _reportService() async {
    // block self-flag in details too
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == widget.ad.ownerId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You can’t report your own service.")),
      );
      return;
    }

    if (_isReportedByMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You already flagged this service.')),
      );
      return;
    }

    final reasons = <String>[
      'Spam',
      'Harassment or bullying',
      'Hate speech',
      'Explicit content',
      'Scam or fraud',
      'Other',
    ];
    String selected = reasons.first;
    final notesCtl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report service'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: selected,
              items: reasons
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => selected = v ?? reasons.first,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtl,
              decoration: const InputDecoration(
                labelText: 'Additional details (optional)',
                hintText: 'Add context for moderators…',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          FilledButton(
            child: const Text('Submit'),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (ok == true) {
      try {
        await _reports.submitServiceReport(
          serviceId: widget.ad.id,
          serviceOwnerId: widget.ad.ownerId,
          serviceTitle: widget.ad.title,
          serviceType: widget.ad.type,
          serviceDescription: widget.ad.description,
          reason: selected,
          notes: notesCtl.text.trim(),
        );
        if (!mounted) return;
        setState(() => _isReportedByMe = true);
        widget.onReportSubmitted();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted. Thank you.')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit report: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isOwner = currentUser != null && widget.ad.ownerId == currentUser.uid;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ad.title),
        backgroundColor: Colors.green,
        actions: [
          // flag only for non-owners
          if (!isOwner)
            IconButton(
              tooltip: _isReportedByMe ? 'You flagged this' : 'Report service',
              icon: Icon(
                _isReportedByMe ? Icons.flag : Icons.flag_outlined,
                color: _isReportedByMe ? Colors.red : Colors.white,
              ),
              onPressed: _isReportedByMe ? null : _reportService,
            ),
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: widget.onEditRequested,
            ),
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteService,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.ad.images.isNotEmpty)
            Column(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: PageView.builder(
                    itemCount: widget.ad.images.length,
                    onPageChanged: (i) => setState(() => _currentPage = i),
                    itemBuilder: (context, idx) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        widget.ad.images[idx],
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
                ),
                if (widget.ad.images.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        widget.ad.images.length,
                        (index) => Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _currentPage == index
                                ? Colors.green
                                : Colors.grey[300],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Text(
            widget.ad.type,
            style: TextStyle(
              color: Colors.grey[700],
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(widget.ad.description, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          if (widget.ad.distanceFromUser != null)
            Text(
              'Distance: ${widget.ad.distanceFromUser!.toStringAsFixed(1)} km',
              style: TextStyle(color: Colors.grey[600]),
            ),
          const SizedBox(height: 20),
          const Divider(),
          const Text(
            'Contact Information',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _isLoadingOwner
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(),
                  ),
                )
              : _owner != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.person,
                                size: 20, color: Colors.green),
                            const SizedBox(width: 8),
                            Text(
                              '${_owner!.firstName} ${_owner!.lastName}',
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
                            final uri = Uri(scheme: 'tel', path: _owner!.phone);
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
                                _owner!.phone,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.blue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () async {
                            final uri =
                                Uri(scheme: 'mailto', path: _owner!.email);
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
                                _owner!.email,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.blue,
                                  decoration: TextDecoration.underline,
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
        ],
      ),
    );
  }
}

/// =======================
/// Full-screen Post Screen (with profanity checks)
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

  final ProfanityFilter _filter = ProfanityFilter();

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
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(width: 1.2, color: Color(0xFFBDBDBD)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(width: 1.8, color: green),
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

    final title = titleCtl.text.trim();
    final desc = descCtl.text.trim();

    if (_filter.hasProfanity(title) || _filter.hasProfanity(desc)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please keep it friendly — title/description contains inappropriate language.',
          ),
        ),
      );
      return;
    }

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title cannot be empty.')),
      );
      return;
    }
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Description cannot be empty.')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final allImages = [..._existingImageUrls];
      for (final x in _pickedImages) {
        final url = await ImageUploadUtil.uploadServiceImageFromXFile(
          x,
          maxSide: 1600,
          quality: 80,
        );
        allImages.add(url);
      }

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
        } catch (_) {}
      }

      final data = <String, dynamic>{
        'ownerId': current.uid,
        'title': title,
        'description': desc,
        'type': dialogType,
        'latitude': geoLat ?? 0.0,
        'longitude': geoLng ?? 0.0,
        'images': allImages,
        'postalCode': postal,
        'price': null,
        'approved': false,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.existingAd == null) {
        data['createdAt'] = FieldValue.serverTimestamp();
        await _firestore.collection('services').add(data);
      } else {
        await _firestore
            .collection('services')
            .doc(widget.existingAd!.id)
            .update(data);
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
    final title =
        widget.existingAd == null ? 'Post New Service' : 'Save Changes';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.green,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
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
                Row(
                  children: [
                    Text(
                      'Images (${_existingImageUrls.length + _pickedImages.length}/5)',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed:
                          _existingImageUrls.length + _pickedImages.length < 5
                              ? _pickImages
                              : null,
                      icon: const Icon(Icons.add_photo_alternate),
                      label: const Text('Add Images'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_existingImageUrls.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
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
                  ),
                if (_pickedImages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
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
                                onTap: () =>
                                    setState(() => _pickedImages.remove(img)),
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
                  ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.check),
                        label: Text(
                          widget.existingAd == null
                              ? 'Post Service'
                              : 'Save Changes',
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
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(false),
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
