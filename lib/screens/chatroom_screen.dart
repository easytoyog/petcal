import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:profanity_filter/profanity_filter.dart';
import 'package:inthepark/widgets/ad_banner.dart';

/// ---------------------------
/// Blocks Service (helpers)
/// ---------------------------
class BlocksService {
  final _db = FirebaseFirestore.instance;
  String? get _me => FirebaseAuth.instance.currentUser?.uid;

  Stream<Set<String>> streamBlockedUids() {
    final me = _me;
    if (me == null) return const Stream.empty();
    return _db
        .collection('users')
        .doc(me)
        .collection('blocks')
        .snapshots()
        .map((s) => s.docs.map((d) => d.id).toSet());
  }

  Future<void> block(String targetUid, {String? reason}) async {
    final me = _me;
    if (me == null || targetUid.isEmpty || targetUid == me) return;
    await _db
        .collection('users')
        .doc(me)
        .collection('blocks')
        .doc(targetUid)
        .set({
      'createdAt': FieldValue.serverTimestamp(),
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason,
    });
  }

  Future<void> unblock(String targetUid) async {
    final me = _me;
    if (me == null || targetUid.isEmpty || targetUid == me) return;
    await _db
        .collection('users')
        .doc(me)
        .collection('blocks')
        .doc(targetUid)
        .delete();
  }
}

/// ---------------------------
/// Reports Service (helpers)
/// ---------------------------
class ReportsService {
  final _db = FirebaseFirestore.instance;
  String? get _me => FirebaseAuth.instance.currentUser?.uid;

  Future<void> submitReport({
    required String reportedUserId,
    required String parkId,
    required String messageText,
    required String messageId,
    required String reason,
    String? notes,
  }) async {
    final me = _me;
    if (me == null || reportedUserId.isEmpty) return;

    await _db.collection('moderation_reports').add({
      'reporterId': me,
      'reportedUserId': reportedUserId,
      'parkId': parkId,
      'messageId': messageId,
      'messageText': messageText,
      'reason': reason,
      'notes': notes ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

/// ---------------------------
/// Chat Room Screen
/// ---------------------------
class ChatRoomScreen extends StatefulWidget {
  final String parkId;
  const ChatRoomScreen({Key? key, required this.parkId}) : super(key: key);

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ProfanityFilter _filter = ProfanityFilter();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _chatStream;
  final String? _currentUid = FirebaseAuth.instance.currentUser?.uid;

  /// senderId -> profile (includes displayName, fallback photo, and primary pet photo)
  final Map<String, _PublicProfile> _profiles = <String, _PublicProfile>{};
  String _parkName = 'Chatroom';

  /// Blocked users (by current user).
  Set<String> _blockedUids = <String>{};

  /// Friends (to mirror FriendsTab schema)
  Set<String> _friendUids = <String>{};

  StreamSubscription<Set<String>>? _blocksSub;
  StreamSubscription<Set<String>>? _friendsSub;

  @override
  void initState() {
    super.initState();

    // Newest first for reverse list (new messages appear at bottom of screen).
    _chatStream = FirebaseFirestore.instance
        .collection('parks')
        .doc(widget.parkId)
        .collection('chat')
        .orderBy('createdAt', descending: true)
        .withConverter<Map<String, dynamic>>(
          fromFirestore: (snap, _) => snap.data() ?? <String, dynamic>{},
          toFirestore: (data, _) => data,
        )
        .snapshots();

    _listenToBlocks();
    _listenToFriendsSameAsTab();
    _fetchParkName();
  }

  void _listenToBlocks() {
    _blocksSub = BlocksService().streamBlockedUids().listen((set) {
      if (mounted) setState(() => _blockedUids = set);
    });
  }

  /// Friends stream that matches your FriendsTab collections:
  /// friends/{me}/userFriends/{friendUid}
  void _listenToFriendsSameAsTab() {
    final me = _currentUid;
    if (me == null) return;
    _friendsSub = FirebaseFirestore.instance
        .collection('friends')
        .doc(me)
        .collection('userFriends')
        .snapshots()
        .map((s) => s.docs.map((d) => d.id).toSet())
        .listen((set) {
      if (mounted) setState(() => _friendUids = set);
    });
  }

  Future<void> _fetchParkName() async {
    try {
      final parkDoc = await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .get();
      if (parkDoc.exists) {
        final data = parkDoc.data();
        setState(() {
          _parkName = (data?['name'] as String?)?.trim().isNotEmpty == true
              ? data!['name'] as String
              : 'Chatroom';
        });
      }
    } catch (_) {}
  }

  /// Warm profile + primary pet caches in batches
  Future<void> _warmProfileCache(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    final missing = <String>{};
    for (final d in docs) {
      final uid = d.data()['senderId'] as String?;
      if (uid != null && uid.isNotEmpty && !_profiles.containsKey(uid)) {
        missing.add(uid);
      }
    }
    if (missing.isEmpty) return;

    final ids = missing.toList();
    for (var i = 0; i < ids.length; i += 10) {
      final batch = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);

      // 1) public profiles
      final profileSnap = await FirebaseFirestore.instance
          .collection('public_profiles')
          .where(FieldPath.documentId, whereIn: batch)
          .get();

      // Pre-fill with empty so we don’t re-query same ids on next frame
      for (final id in batch) {
        _profiles.putIfAbsent(id, () => const _PublicProfile.empty());
      }

      for (final p in profileSnap.docs) {
        final d = p.data();
        final displayName = (d['displayName'] ?? '') as String? ?? '';
        final photoUrl = (d['photoUrl'] ?? '') as String? ?? '';
        final existing = _profiles[p.id] ?? const _PublicProfile.empty();
        _profiles[p.id] = existing.copyWith(
          displayName: displayName,
          profilePhotoUrl: photoUrl,
        );
      }

      // 2) pets for those owners
      final petsSnap = await FirebaseFirestore.instance
          .collection('pets')
          .where('ownerId', whereIn: batch)
          .get();

      final Map<String, List<QueryDocumentSnapshot>> petsByOwner = {};
      for (final petDoc in petsSnap.docs) {
        final data = petDoc.data();
        final ownerId = (data['ownerId'] ?? '') as String;
        (petsByOwner[ownerId] ??= []).add(petDoc);
      }

      for (final ownerId in batch) {
        final petDocs = petsByOwner[ownerId] ?? const <QueryDocumentSnapshot>[];
        String primaryPhoto = '';

        if (petDocs.isNotEmpty) {
          QueryDocumentSnapshot? mainPetDoc;
          for (final d in petDocs) {
            final mp = (d.data() as Map<String, dynamic>);
            if (mp['isMain'] == true) {
              mainPetDoc = d;
              break;
            }
          }
          final chosen = mainPetDoc ?? petDocs.first;
          final chosenData = (chosen.data() as Map<String, dynamic>);
          final pUrl = (chosenData['photoUrl'] ?? '') as String?;
          if (pUrl != null && pUrl.trim().isNotEmpty) {
            primaryPhoto = pUrl.trim();
          }
        }

        final existing = _profiles[ownerId] ?? const _PublicProfile.empty();
        _profiles[ownerId] =
            existing.copyWith(primaryPetPhotoUrl: primaryPhoto);
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _sendMessage() async {
    final uid = _currentUid;
    if (uid == null) return;

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    if (_filter.hasProfanity(text)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your message contains inappropriate language.'),
        ),
      );
      return;
    }

    // WhatsApp-style: clear but keep keyboard open
    _messageController.clear();
    _inputFocus.requestFocus();

    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('chat')
          .add({
        'senderId': uid,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sending message: $e')),
      );
    }
  }

  Future<void> _blockUser(String targetUid) async {
    try {
      await BlocksService().block(targetUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('User blocked. Their messages are now hidden.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to block user: $e')),
      );
    }
  }

  Future<void> _unblockUser(String targetUid) async {
    try {
      await BlocksService().unblock(targetUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User unblocked.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unblock user: $e')),
      );
    }
  }

  Future<void> _reportUserDialog({
    required String targetUid,
    required String messageText,
    required String messageId,
  }) async {
    final reasons = <String>[
      'Spam',
      'Harassment or bullying',
      'Hate speech',
      'Explicit content',
      'Scam or fraud',
      'Other',
    ];
    String selected = reasons.first;
    final notesController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report user'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: selected,
              items: reasons
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => selected = v ?? reasons.first,
              decoration: const InputDecoration(
                labelText: 'Reason',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesController,
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

    if (confirmed == true) {
      try {
        await ReportsService().submitReport(
          reportedUserId: targetUid,
          parkId: widget.parkId,
          messageText: messageText,
          messageId: messageId,
          reason: selected,
          notes: notesController.text.trim(),
        );
        if (!mounted) return;
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

  /// ---------------------------
  /// Add Friend (FriendsTab schema)
  /// friends/{me}/userFriends/{friendUserId} + favorites/{me}/pets/{petId}
  /// ---------------------------
  Future<void> _addFriendSameAsFriendsTab(String friendUserId) async {
    final me = _currentUid;
    if (me == null || friendUserId.isEmpty || me == friendUserId) return;

    try {
      // 0) If already friends, bail.
      final already = await FirebaseFirestore.instance
          .collection('friends')
          .doc(me)
          .collection('userFriends')
          .doc(friendUserId)
          .get();
      if (already.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already friends.')),
          );
        }
        return;
      }

      // 1) Resolve owner name (owners -> public_profiles -> uid)
      String ownerName = '';
      try {
        final ownerDoc = await FirebaseFirestore.instance
            .collection('owners')
            .doc(friendUserId)
            .get();
        if (ownerDoc.exists) {
          final m = ownerDoc.data() as Map<String, dynamic>;
          final firstName =
              (m['firstName'] ?? m['first_name'] ?? '').toString();
          final lastName = (m['lastName'] ?? m['last_name'] ?? '').toString();
          ownerName = '$firstName $lastName'.trim();
        }
      } catch (_) {}
      if (ownerName.isEmpty) {
        try {
          final pp = await FirebaseFirestore.instance
              .collection('public_profiles')
              .doc(friendUserId)
              .get();
          final dn = (pp.data()?['displayName'] ?? '').toString().trim();
          if (dn.isNotEmpty) ownerName = dn;
        } catch (_) {}
      }
      if (ownerName.isEmpty) ownerName = friendUserId;

      // 2) Pick a representative petId (prefer isMain==true)
      String? petId;
      try {
        final petsSnap = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', isEqualTo: friendUserId)
            .get();

        if (petsSnap.docs.isNotEmpty) {
          QueryDocumentSnapshot? mainPet;
          for (final d in petsSnap.docs) {
            final mp = d.data();
            if (mp['isMain'] == true) {
              mainPet = d;
              break;
            }
          }
          final chosen = mainPet ?? petsSnap.docs.first;
          petId = chosen.id;
        }
      } catch (_) {}

      // 3) Write friend doc (same as FriendsTab)
      await FirebaseFirestore.instance
          .collection('friends')
          .doc(me)
          .collection('userFriends')
          .doc(friendUserId)
          .set({
        'friendId': friendUserId,
        'ownerName': ownerName,
        'addedAt': FieldValue.serverTimestamp(),
      });

      // 4) If we found a pet, mirror the "favorite" add like FriendsTab
      if (petId != null && petId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('favorites')
            .doc(me)
            .collection('pets')
            .doc(petId)
            .set({
          'petId': petId,
          'addedAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend added.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adding friend: $e')),
      );
    }
  }

  void _showMessageActions({
    required String senderId,
    required String displayName,
    required bool isMe,
    required String messageText,
    required String messageId,
  }) {
    if (isMe) return;
    final isBlocked = _blockedUids.contains(senderId);
    final isFriend = _friendUids.contains(senderId);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Add friend / Friends
              ListTile(
                leading: Icon(isFriend ? Icons.check_circle : Icons.person_add),
                title: Text(isFriend ? 'Friends' : 'Add friend'),
                enabled: !isFriend,
                onTap: !isFriend
                    ? () {
                        Navigator.of(context).pop();
                        _addFriendSameAsFriendsTab(senderId);
                      }
                    : null,
              ),

              // Block / Unblock
              ListTile(
                leading: Icon(isBlocked ? Icons.lock_open : Icons.block),
                title: Text(
                    isBlocked ? 'Unblock $displayName' : 'Block $displayName'),
                subtitle: Text(isBlocked
                    ? 'Allow messages from this user again'
                    : 'Hide all messages from this user'),
                onTap: () {
                  Navigator.of(context).pop();
                  if (isBlocked) {
                    _unblockUser(senderId);
                  } else {
                    _blockUser(senderId);
                  }
                },
              ),

              // Report
              ListTile(
                leading: const Icon(Icons.report),
                title: const Text('Report user'),
                subtitle: const Text('Flag this message for moderation'),
                onTap: () {
                  Navigator.of(context).pop();
                  _reportUserDialog(
                    targetUid: senderId,
                    messageText: messageText,
                    messageId: messageId,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Visible ⋮ menu for desktop/web + long-press alternative
  Widget _messageActionsMenu({
    required String senderId,
    required String displayName,
    required bool isMe,
    required String messageText,
    required String messageId,
  }) {
    if (isMe) return const SizedBox.shrink();
    final isBlocked = _blockedUids.contains(senderId);
    final isFriend = _friendUids.contains(senderId);

    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (value) {
        if (value == 'block') {
          if (isBlocked) {
            _unblockUser(senderId);
          } else {
            _blockUser(senderId);
          }
        } else if (value == 'report') {
          _reportUserDialog(
            targetUid: senderId,
            messageText: messageText,
            messageId: messageId,
          );
        } else if (value == 'add_friend') {
          _addFriendSameAsFriendsTab(senderId);
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        // Add friend / Friends
        PopupMenuItem<String>(
          value: 'add_friend',
          enabled: !isFriend,
          child: Row(
            children: [
              Icon(
                isFriend ? Icons.check_circle : Icons.person_add,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(isFriend ? 'Friends' : 'Add friend'),
            ],
          ),
        ),
        const PopupMenuDivider(height: 8),
        // Block / Unblock
        PopupMenuItem<String>(
          value: 'block',
          child: Row(
            children: [
              Icon(isBlocked ? Icons.lock_open : Icons.block,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(isBlocked ? 'Unblock user' : 'Block user'),
            ],
          ),
        ),
        const PopupMenuDivider(height: 8),
        // Report
        PopupMenuItem<String>(
          value: 'report',
          child: Row(
            children: [
              Icon(Icons.report,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              const Text('Report user'),
            ],
          ),
        ),
      ],
      icon: const Icon(Icons.more_vert, size: 20),
    );
  }

  Widget _messageTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final senderId = (data['senderId'] as String?) ?? '';
    final text = (data['text'] as String?) ?? '';
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
    final messageId = doc.id;

    final me = senderId == _currentUid;

    final profile = _profiles[senderId] ?? const _PublicProfile.empty();
    final name =
        profile.displayName.isNotEmpty ? profile.displayName : 'Someone';

    // Avatar priority: primaryPetPhoto -> profilePhoto -> fallback icon
    final avatarUrl = profile.primaryPetPhotoUrl.isNotEmpty
        ? profile.primaryPetPhotoUrl
        : (profile.profilePhotoUrl.isNotEmpty ? profile.profilePhotoUrl : '');

    final timeString =
        createdAt == null ? '' : DateFormat('MMM d, h:mm a').format(createdAt);

    final bubbleColor = me ? Colors.green.shade100 : Colors.grey.shade200;

    final avatarWidget = CircleAvatar(
      radius: 18,
      backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
      child: avatarUrl.isEmpty ? const Icon(Icons.pets, size: 18) : null,
    );

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment:
            me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(name,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Text(timeString,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      child: GestureDetector(
        onLongPress: () => _showMessageActions(
          senderId: senderId,
          displayName: name,
          isMe: me,
          messageText: text,
          messageId: messageId,
        ),
        child: Row(
          mainAxisAlignment:
              me ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: me
              ? <Widget>[
                  // My message (no menu)
                  bubble,
                  const SizedBox(width: 8),
                  avatarWidget,
                ]
              : <Widget>[
                  // Other user's message: avatar, bubble, then ⋮ menu
                  avatarWidget,
                  const SizedBox(width: 8),
                  Flexible(child: bubble),
                  const SizedBox(width: 4),
                  _messageActionsMenu(
                    senderId: senderId,
                    displayName: name,
                    isMe: me,
                    messageText: text,
                    messageId: messageId,
                  ),
                ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      appBar: AppBar(
        title: Text('Park Chat: $_parkName'),
        backgroundColor: const Color(0xFF567D46),
        actions: [
          IconButton(
            tooltip: 'Blocked users',
            icon: const Icon(Icons.block),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
              );
            },
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // Messages
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _chatStream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('Error loading chat.'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // Filter out blocked senders locally
                  final allDocs = snapshot.data!.docs;
                  final docs = allDocs.where((d) {
                    final sid = (d.data()['senderId'] as String?) ?? '';
                    return !_blockedUids.contains(sid);
                  }).toList();

                  // Warm profile caches
                  _warmProfileCache(docs);

                  // EMPTY STATE
                  if (docs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24.0, vertical: 16.0),
                        child: Text(
                          "No one's posted anything yet — be the first to say something in this park!",
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true, // newest messages rendered from bottom up
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, i) => _messageTile(docs[i]),
                  );
                },
              ),
            ),

            // Composer
            Padding(
              padding: EdgeInsets.fromLTRB(
                  8, 0, 8, (bottomSafe > 0 ? bottomSafe : 8)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 2,
                        offset: Offset(0, 1))
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _inputFocus,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        minLines: 1,
                        maxLines: 5, // allow gentle growth like WhatsApp
                        keyboardType: TextInputType.multiline,
                        decoration: const InputDecoration(
                          hintText: 'Type a message…',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFF567D46)),
                      onPressed: _sendMessage,
                    ),
                  ],
                ),
              ),
            ),

            // Ad (optional)
            const AdBanner(),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _inputFocus.dispose();
    _scrollController.dispose();
    _blocksSub?.cancel();
    _friendsSub?.cancel();
    super.dispose();
  }
}

/// Profile cache entry
class _PublicProfile {
  final String displayName;
  final String profilePhotoUrl; // from public_profiles.photoUrl
  final String primaryPetPhotoUrl; // chosen pet photo (isMain -> first)

  const _PublicProfile({
    required this.displayName,
    required this.profilePhotoUrl,
    required this.primaryPetPhotoUrl,
  });

  const _PublicProfile.empty()
      : displayName = '',
        profilePhotoUrl = '',
        primaryPetPhotoUrl = '';

  _PublicProfile copyWith({
    String? displayName,
    String? profilePhotoUrl,
    String? primaryPetPhotoUrl,
  }) {
    return _PublicProfile(
      displayName: displayName ?? this.displayName,
      profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
      primaryPetPhotoUrl: primaryPetPhotoUrl ?? this.primaryPetPhotoUrl,
    );
  }
}

/// ---------------------------
/// Blocked Users Management UI
/// ---------------------------
class BlockedUsersScreen extends StatelessWidget {
  const BlockedUsersScreen({Key? key}) : super(key: key);

  Future<_ProfileLite?> _fetchProfile(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('public_profiles')
          .doc(uid)
          .get();
      if (!doc.exists) return null;
      final d = doc.data() as Map<String, dynamic>;
      return _ProfileLite(
        uid: uid,
        displayName: (d['displayName'] ?? '') as String? ?? '',
        photoUrl: (d['photoUrl'] ?? '') as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = BlocksService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blocked users'),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: StreamBuilder<Set<String>>(
        stream: service.streamBlockedUids(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final blocked = snap.data ?? <String>{};
          if (blocked.isEmpty) {
            return const Center(child: Text('No one is blocked.'));
          }

          final uids = blocked.toList();

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: uids.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final uid = uids[i];
              return FutureBuilder<_ProfileLite?>(
                future: _fetchProfile(uid),
                builder: (context, profSnap) {
                  final p = profSnap.data;
                  final title = (p?.displayName.trim().isNotEmpty ?? false)
                      ? p!.displayName
                      : uid;
                  final avatarUrl = p?.photoUrl ?? '';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage:
                          avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                      child:
                          avatarUrl.isEmpty ? const Icon(Icons.person) : null,
                    ),
                    title: Text(title),
                    subtitle: Text(uid, style: const TextStyle(fontSize: 12)),
                    trailing: TextButton.icon(
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Unblock'),
                      onPressed: () async {
                        await service.unblock(uid);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Unblocked $title')),
                          );
                        }
                      },
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _ProfileLite {
  final String uid;
  final String displayName;
  final String photoUrl;
  _ProfileLite({
    required this.uid,
    required this.displayName,
    required this.photoUrl,
  });
}
