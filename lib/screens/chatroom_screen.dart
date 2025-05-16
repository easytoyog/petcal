import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:profanity_filter/profanity_filter.dart';
import 'package:pet_calendar/widgets/ad_banner.dart';

class ChatRoomScreen extends StatefulWidget {
  final String parkId;
  const ChatRoomScreen({Key? key, required this.parkId}) : super(key: key);

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _messageController = TextEditingController();
  late Stream<QuerySnapshot> _chatStream;
  final String? currentUserId = FirebaseAuth.instance.currentUser?.uid;
  final ProfanityFilter filter = ProfanityFilter();

  // Caches for sender's pet and owner info.
  final Map<String, Map<String, dynamic>> _petInfoCache = {};
  final Map<String, Map<String, dynamic>> _ownerInfoCache = {};
  String parkName = "Chatroom";

  @override
  void initState() {
    super.initState();
    _chatStream = FirebaseFirestore.instance
        .collection('parks')
        .doc(widget.parkId)
        .collection('chat')
        .orderBy('timestamp', descending: false)
        .snapshots();
    _fetchParkName();
  }

  Future<void> _fetchParkName() async {
    try {
      DocumentSnapshot parkDoc = await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .get();
      if (parkDoc.exists) {
        final data = parkDoc.data() as Map<String, dynamic>;
        setState(() {
          parkName = data['name'] ?? "Chatroom";
        });
      }
    } catch (e) {
      print("Error fetching park name: $e");
    }
  }

  // Batch fetch and cache all pet and owner info for the chat messages
  Future<void> _preloadChatUserInfo(List<QueryDocumentSnapshot> docs) async {
    final senderIds =
        docs.map((d) => d['senderId'] as String? ?? "").toSet().toList();
    // Fetch pets in batch
    List<String> idsToFetch =
        senderIds.where((id) => !_petInfoCache.containsKey(id)).toList();
    if (idsToFetch.isNotEmpty) {
      int chunkSize = 10;
      for (int i = 0; i < idsToFetch.length; i += chunkSize) {
        List<String> chunk = idsToFetch.sublist(
            i,
            i + chunkSize > idsToFetch.length
                ? idsToFetch.length
                : i + chunkSize);
        QuerySnapshot petSnap = await FirebaseFirestore.instance
            .collection('pets')
            .where('ownerId', whereIn: chunk)
            .where('isPrimary', isEqualTo: true)
            .get();
        for (var doc in petSnap.docs) {
          final pet = doc.data() as Map<String, dynamic>;
          _petInfoCache[pet['ownerId']] = pet;
        }
        // Fallback for users with no primary pet
        List<String> missing =
            chunk.where((id) => !_petInfoCache.containsKey(id)).toList();
        if (missing.isNotEmpty) {
          QuerySnapshot fallbackSnap = await FirebaseFirestore.instance
              .collection('pets')
              .where('ownerId', whereIn: missing)
              .limit(1)
              .get();
          for (var doc in fallbackSnap.docs) {
            final pet = doc.data() as Map<String, dynamic>;
            _petInfoCache[pet['ownerId']] = pet;
          }
        }
      }
    }
    // Fetch owners in batch
    List<String> ownerIdsToFetch =
        senderIds.where((id) => !_ownerInfoCache.containsKey(id)).toList();
    if (ownerIdsToFetch.isNotEmpty) {
      int chunkSize = 10;
      for (int i = 0; i < ownerIdsToFetch.length; i += chunkSize) {
        List<String> chunk = ownerIdsToFetch.sublist(
            i,
            i + chunkSize > ownerIdsToFetch.length
                ? ownerIdsToFetch.length
                : i + chunkSize);
        QuerySnapshot ownerSnap = await FirebaseFirestore.instance
            .collection('owners')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (var doc in ownerSnap.docs) {
          final owner = doc.data() as Map<String, dynamic>;
          _ownerInfoCache[doc.id] = owner;
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleMessageLike(DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final uid = currentUserId;
    if (uid == null) return;
    final ref = doc.reference;
    final likes = List<String>.from(data['likes'] ?? []);
    try {
      if (likes.contains(uid)) {
        await ref.update({
          'likes': FieldValue.arrayRemove([uid])
        });
      } else {
        await ref.update({
          'likes': FieldValue.arrayUnion([uid])
        });
      }
    } catch (e) {
      print("Error toggling message like: $e");
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (filter.hasProfanity(text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Your message contains inappropriate language.")),
      );
      return;
    }
    final expireAt = DateTime.now().add(const Duration(days: 30));
    final data = {
      'senderId': currentUserId,
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(expireAt),
      'likes': [],
    };
    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('chat')
          .add(data);
      _messageController.clear();
    } catch (e) {
      print("Error sending message: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error sending message.")),
      );
    }
  }

  Widget _buildChatMessageTile(DocumentSnapshot doc) {
    final data = doc.data()! as Map<String, dynamic>;
    final senderId = data['senderId'] as String? ?? "";
    final text = data['text'] as String? ?? "";
    final timestamp = (data['timestamp'] as Timestamp?)?.toDate();
    final timeString = timestamp != null
        ? DateFormat('yyyy-MM-dd HH:mm').format(timestamp)
        : "";
    final isMe = senderId == currentUserId;

    // Use cached pet and owner info
    final pet = _petInfoCache[senderId];
    final owner = _ownerInfoCache[senderId];
    final petName = pet?['name'] ?? "Unknown Pet";
    final petPhoto = pet?['photoUrl'] ?? "";
    final ownerName = owner != null
        ? "${owner['firstName'] ?? ''} ${owner['lastName'] ?? ''}"
                .trim()
                .isEmpty
            ? "Unknown"
            : "${owner['firstName']} ${owner['lastName']}"
        : "Unknown";
    final displayName = "$petName ($ownerName)";
    final likes = List<String>.from(data['likes'] ?? []);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              CircleAvatar(
                radius: 20,
                backgroundImage:
                    petPhoto.isNotEmpty ? NetworkImage(petPhoto) : null,
                child: petPhoto.isEmpty ? const Icon(Icons.pets) : null,
              ),
            const SizedBox(width: 6),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: isMe ? Colors.blue[100] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 2,
                      offset: const Offset(1, 1),
                    )
                  ],
                ),
                child: Column(
                  crossAxisAlignment:
                      isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(text, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          timeString,
                          style:
                              const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.thumb_up,
                              size: 16, color: Colors.green),
                          onPressed: () => _toggleMessageLike(doc),
                        ),
                        Text("${likes.length}",
                            style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (isMe)
              CircleAvatar(
                radius: 20,
                backgroundImage:
                    petPhoto.isNotEmpty ? NetworkImage(petPhoto) : null,
                child: petPhoto.isEmpty ? const Icon(Icons.pets) : null,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Park Chat: $parkName"),
        backgroundColor: const Color(0xFF567D46),
      ),
      body: Column(
        children: [
          // Chat messages list
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _chatStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(child: Text("Error loading chat."));
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                // Preload all pet and owner info for these messages
                _preloadChatUserInfo(docs);
                return ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _buildChatMessageTile(docs[i]),
                );
              },
            ),
          ),

          // Message input up above the ad
          Container(
            margin: const EdgeInsets.all(8.0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                    color: Colors.black12, blurRadius: 2, offset: Offset(0, 1)),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: "Type a message...",
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.teal),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),

          // Persistent ad banner at bottom
          const AdBanner(),
        ],
      ),
    );
  }
}
