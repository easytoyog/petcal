import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.currentUserName,
  });

  final String groupId;
  final String groupName;
  final String currentUserName;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _sending = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _groupSub;

  DocumentReference<Map<String, dynamic>> get _groupRef =>
      _firestore.collection('groups').doc(widget.groupId);

  DocumentReference<Map<String, dynamic>>? get _readRef {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    return _firestore
        .collection('owners')
        .doc(uid)
        .collection('group_chat_reads')
        .doc(widget.groupId);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream() {
    return _firestore
        .collection('groups')
        .doc(widget.groupId)
        .collection('messages')
        .orderBy('createdAt', descending: false)
        .snapshots();
  }

  Future<void> _sendMessage() async {
    final user = _auth.currentUser;
    final text = _messageController.text.trim();

    if (user == null) return;
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    try {
      final msgRef = _firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('messages')
          .doc();

      final senderName =
          widget.currentUserName.isEmpty ? 'Unknown' : widget.currentUserName;
      final batch = _firestore.batch();

      batch.set(msgRef, {
        'text': text,
        'senderId': user.uid,
        'senderName': senderName,
        'createdAt': FieldValue.serverTimestamp(),
        'type': 'text',
      });

      batch.set(
        _groupRef,
        {
          'lastMessage': text,
          'lastMessageAt': FieldValue.serverTimestamp(),
          'lastMessageSenderId': user.uid,
        },
        SetOptions(merge: true),
      );

      await batch.commit();
      await _markAsRead();

      _messageController.clear();

      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _formatTime(Timestamp? ts) {
    if (ts == null) return '';
    return DateFormat('h:mm a').format(ts.toDate());
  }

  String _formatDateLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(dt.year, dt.month, dt.day);

    if (day == today) return 'Today';
    if (day == yesterday) return 'Yesterday';
    return DateFormat('MMM d, yyyy').format(dt);
  }

  Future<void> _markAsRead([Timestamp? seenAt]) async {
    final ref = _readRef;
    final uid = _auth.currentUser?.uid;
    if (ref == null || uid == null) return;

    await ref.set(
      {
        'groupId': widget.groupId,
        'lastReadAt': seenAt ?? FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  void _listenForReadUpdates() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    _groupSub = _groupRef.snapshots().listen((snap) {
      final data = snap.data();
      if (data == null) return;

      final lastSenderId = (data['lastMessageSenderId'] ?? '').toString();
      final lastMessageAt = data['lastMessageAt'];
      if (lastSenderId.isEmpty || lastSenderId == uid) return;
      if (lastMessageAt is! Timestamp) return;

      _markAsRead(lastMessageAt);
    });
  }

  @override
  void initState() {
    super.initState();
    _listenForReadUpdates();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markAsRead();
    });
  }

  bool _shouldShowDateHeader(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int index,
  ) {
    final currentTs = docs[index].data()['createdAt'] as Timestamp?;
    if (currentTs == null) return index == 0;

    if (index == 0) return true;

    final prevTs = docs[index - 1].data()['createdAt'] as Timestamp?;
    if (prevTs == null) return true;

    final current = currentTs.toDate();
    final prev = prevTs.toDate();

    return current.year != prev.year ||
        current.month != prev.month ||
        current.day != prev.day;
  }

  Widget _buildDateHeader(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble({
    required bool isMe,
    required String text,
    required String senderName,
    required Timestamp? createdAt,
  }) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 290),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMe ? 14 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  senderName,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF567D46),
                  ),
                ),
              ),
            Text(
              text,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.black87,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(createdAt),
              style: TextStyle(
                fontSize: 11,
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _groupSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = _auth.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        backgroundColor: const Color(0xFF567D46),
        elevation: 2,
      ),
      backgroundColor: const Color(0xFFEFEAE2),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _messagesStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading chat: ${snapshot.error}'),
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet. Start the conversation!',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(
                      _scrollController.position.maxScrollExtent,
                    );
                  }
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final text = (data['text'] ?? '') as String;
                    final senderId = (data['senderId'] ?? '') as String;
                    final senderName =
                        (data['senderName'] ?? 'Unknown') as String;
                    final createdAt = data['createdAt'] as Timestamp?;
                    final isMe = senderId == currentUid;

                    final children = <Widget>[];

                    if (createdAt != null &&
                        _shouldShowDateHeader(docs, index)) {
                      children.add(_buildDateHeader(
                          _formatDateLabel(createdAt.toDate())));
                    }

                    children.add(
                      _buildBubble(
                        isMe: isMe,
                        text: text,
                        senderName: senderName,
                        createdAt: createdAt,
                      ),
                    );

                    return Column(children: children);
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              color: const Color(0xFFF7F7F7),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFF567D46),
                    child: IconButton(
                      onPressed: _sending ? null : _sendMessage,
                      icon: const Icon(Icons.send, color: Colors.white),
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
