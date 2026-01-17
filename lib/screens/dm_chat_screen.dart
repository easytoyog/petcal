import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class DmChatScreen extends StatefulWidget {
  final String otherUserId;
  final String otherDisplayName;

  const DmChatScreen({
    super.key,
    required this.otherUserId,
    required this.otherDisplayName,
  });

  @override
  State<DmChatScreen> createState() => _DmChatScreenState();
}

class _DmChatScreenState extends State<DmChatScreen> {
  final _db = FirebaseFirestore.instance;
  final _textCtl = TextEditingController();
  final _scrollCtl = ScrollController();

  String? get _me => FirebaseAuth.instance.currentUser?.uid;

  bool _sending = false;
  bool _threadReady = false;
  String? _initError;

  String get _threadId {
    final me = _me ?? '';
    final other = widget.otherUserId;
    if (me.compareTo(other) < 0) return '${me}_$other';
    return '${other}_$me';
  }

  DocumentReference<Map<String, dynamic>> get _threadRef =>
      _db.collection('dm_threads').doc(_threadId);

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      _threadRef.collection('messages');

  @override
  void initState() {
    super.initState();
    _initThread();
  }

  Future<void> _initThread() async {
    final me = _me;
    if (me == null) {
      setState(() {
        _initError = "Not signed in";
      });
      return;
    }

    try {
      await _ensureThreadExists();
      if (!mounted) return;
      setState(() {
        _threadReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = "Failed to init chat: $e";
      });
    }
  }

  @override
  void dispose() {
    _textCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _ensureThreadExists() async {
    final me = _me;
    if (me == null) return;

    final doc = await _threadRef.get();
    if (doc.exists) return;

    final participants = [me, widget.otherUserId]..sort();
    final now = Timestamp.now();

    await _threadRef.set({
      'participants': participants,
      'participantsMap': {
        participants[0]: true,
        participants[1]: true,
      },
      'lastMessage': '',
      'lastSenderId': '',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final me = _me;
    if (me == null) return;

    final text = _textCtl.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);

    try {
      // Thread should already exist, but this is safe
      await _ensureThreadExists();

      await _db.runTransaction((tx) async {
        final threadSnap = await tx.get(_threadRef);
        if (!threadSnap.exists) {
          throw Exception("Thread doc missing after ensure.");
        }

        final msgRef = _messagesRef.doc();
        final now = Timestamp.now();

        tx.set(msgRef, {
          'senderId': me,
          'text': text,
          'createdAt': now,
        });

        tx.set(
          _threadRef,
          {
            'lastMessage': text,
            'lastSenderId': me,
            'updatedAt': now,
          },
          SetOptions(merge: true),
        );
      });

      _textCtl.clear();
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _bubble({
    required bool isMe,
    required String text,
    required Timestamp? createdAt,
  }) {
    final time = createdAt?.toDate();
    final timeStr =
        time == null ? '' : TimeOfDay.fromDateTime(time).format(context);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: const TextStyle(fontSize: 15, height: 1.25),
            ),
            if (timeStr.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.black.withOpacity(0.45),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    )
                  ],
                ),
                child: TextField(
                  controller: _textCtl,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton(
              heroTag: 'dm_send_btn',
              mini: true,
              backgroundColor: Colors.green,
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) {
      return const Scaffold(body: Center(child: Text('Please sign in')));
    }

    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.green,
          title: Text(widget.otherDisplayName),
        ),
        body: Center(child: Text(_initError!)),
      );
    }

    if (!_threadReady) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.green,
          title: Text(widget.otherDisplayName),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final query = _messagesRef.orderBy('createdAt', descending: true).limit(60);

    return Scaffold(
      backgroundColor: const Color(0xFFECE5DD),
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Text(widget.otherDisplayName),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: query.snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Text('Stream error: ${snap.error}'),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap.data?.docs ?? [];

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollCtl.hasClients) _scrollCtl.jumpTo(0);
                });

                return ListView.builder(
                  controller: _scrollCtl,
                  reverse: true,
                  padding: const EdgeInsets.only(top: 10, bottom: 10),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final m = docs[i].data();
                    final senderId = (m['senderId'] ?? '').toString();
                    final text = (m['text'] ?? '').toString();
                    final ts = m['createdAt'];
                    final createdAt = ts is Timestamp ? ts : null;

                    return _bubble(
                      isMe: senderId == me,
                      text: text,
                      createdAt: createdAt,
                    );
                  },
                );
              },
            ),
          ),
          _composer(),
        ],
      ),
    );
  }
}
