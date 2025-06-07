import 'package:cloud_firestore/cloud_firestore.dart';

class FeedbackModel {
  final String id;
  final String feedback;
  final String? userId;
  final DateTime timestamp;

  FeedbackModel({
    required this.id,
    required this.feedback,
    required this.userId,
    required this.timestamp,
  });

  factory FeedbackModel.fromFirestore(String id, Map<String, dynamic> data) {
    return FeedbackModel(
      id: id,
      feedback: data['feedback'] ?? '',
      userId: data['userId'],
      timestamp: (data['timestamp'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'feedback': feedback,
      'userId': userId,
      'timestamp': timestamp,
    };
  }
}
