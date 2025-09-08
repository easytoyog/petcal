import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:profanity_filter/profanity_filter.dart';
import 'package:inthepark/widgets/ad_banner.dart';

class ChatRoomScreen extends StatefulWidget {
  final String parkId;
  const ChatRoomScreen({Key? key, required this.parkId}) : super(key: key);

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ProfanityFilter _filter = ProfanityFilter();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _chatStream;
  final String? _currentUid = FirebaseAuth.instance.currentUser?.uid;

  final Map<String, _PublicProfile> _profiles = <String, _PublicProfile>{};
  String _parkName = 'Chatroom';

  @override
  void initState() {
    super.initState();

    _chatStream = FirebaseFirestore.instance
        .collection('parks')
        .doc(widget.parkId)
        .collection('chat')
        .orderBy('createdAt', descending: false)
        .withConverter<Map<String, dynamic>>(
          fromFirestore: (snap, _) => snap.data() ?? <String, dynamic>{},
          toFirestore: (data, _) => data,
        )
        .snapshots();

    _fetchParkName();
  }

  Future<void> _fetchParkName() async {
    try {
      final parkDoc = await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .get();

      if (parkDoc.exists) {
        final data = parkDoc.data() as Map<String, dynamic>?;
        setState(() {
          _parkName = (data?['name'] as String?)?.trim().isNotEmpty == true
              ? data!['name'] as String
              : 'Chatroom';
        });
      }
    } catch (_) {}
  }

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
      final snap = await FirebaseFirestore.instance
          .collection('public_profiles')
          .where(FieldPath.documentId, whereIn: batch)
          .get();

      for (final p in snap.docs) {
        final d = p.data() as Map<String, dynamic>;
        _profiles[p.id] = _PublicProfile(
          displayName: (d['displayName'] ?? '') as String,
          photoUrl: (d['photoUrl'] ?? '') as String,
        );
      }

      for (final id in batch) {
        _profiles.putIfAbsent(id, () => const _PublicProfile.empty());
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
            content: Text('Your message contains inappropriate language.')),
      );
      return;
    }

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

      _messageController.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sending message: $e')),
      );
    }
  }

  Widget _messageTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final senderId = (data['senderId'] as String?) ?? '';
    final text = (data['text'] as String?) ?? '';
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

    final me = senderId == _currentUid;

    final profile = _profiles[senderId] ?? const _PublicProfile.empty();
    final name =
        profile.displayName.isNotEmpty ? profile.displayName : 'Someone';
    final avatar = profile.photoUrl;

    final timeString =
        createdAt == null ? '' : DateFormat('MMM d, h:mm a').format(createdAt);

    final bubbleColor = me ? Colors.green.shade100 : Colors.grey.shade200;

    final avatarWidget = CircleAvatar(
      radius: 18,
      backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
      child: avatar.isEmpty ? const Icon(Icons.pets, size: 18) : null,
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
      child: Row(
        mainAxisAlignment:
            me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: me
            ? <Widget>[bubble, const SizedBox(width: 8), avatarWidget]
            : <Widget>[avatarWidget, const SizedBox(width: 8), bubble],
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
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        // top/bottom safe area so nothing gets under status/nav bars
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

                  final docs = snapshot.data!.docs;

                  _warmProfileCache(docs);

                  if (docs.isEmpty) {
                    return const Center(child: Text('Be the first to say hi 👋'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, i) => _messageTile(docs[i]),
                  );
                },
              ),
            ),

            // Composer (kept above nav bar & above keyboard)
            Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, (bottomSafe > 0 ? bottomSafe : 8)),
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
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
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

            // Ad (also inside SafeArea so it won’t be cut off)
            const AdBanner(),
          ],
        ),
      ),
    );
  }
}

class _PublicProfile {
  final String displayName;
  final String photoUrl;
  const _PublicProfile({required this.displayName, required this.photoUrl});
  const _PublicProfile.empty()
      : displayName = '',
        photoUrl = '';
}
