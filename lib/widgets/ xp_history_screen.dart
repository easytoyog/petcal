import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class XpHistoryScreen extends StatelessWidget {
  const XpHistoryScreen({Key? key}) : super(key: key);

  String _formatTimestamp(Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate().toLocal();
    // simple formatting without intl
    final date =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final xpLogsQuery = FirebaseFirestore.instance
        .collection('owners')
        .doc(uid)
        .collection('xpLogs')
        .orderBy('createdAt', descending: true)
        .limit(200); // adjust if you want more

    return Scaffold(
      appBar: AppBar(
        title: const Text('XP History'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: xpLogsQuery.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('Error loading XP history'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('No XP history yet. Go play in the park! 🐶'),
            );
          }

          return ListView(
            children: [
              // XP EXPLANATION BANNER
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "How XP Works 🐾",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        "• **Daily Park Check-In:** Earns XP once per day.\n"
                        "• **Walk XP:** Based on walk duration + step count and your streak count. The longer your streak the bigger the bonus!\n",
                        style: TextStyle(fontSize: 14, height: 1.35),
                      ),
                    ],
                  ),
                ),
              ),

              // XP LOGS LIST
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final amount = (data['amount'] ?? 0) as int;
                  final reason = (data['reason'] ?? 'XP gain') as String;
                  final ts = data['createdAt'] as Timestamp?;
                  final levelAfter = data['levelAfter'];

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.amber.shade200,
                      child: Text(
                        '+$amount',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.brown,
                        ),
                      ),
                    ),
                    title: Text(reason),
                    subtitle: Text(_formatTimestamp(ts)),
                    trailing: levelAfter != null
                        ? Text(
                            'Lvl $levelAfter',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
