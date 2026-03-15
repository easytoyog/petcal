import 'package:cloud_firestore/cloud_firestore.dart';

class PetDocumentRecord {
  final String id;
  final String petId;
  final String ownerId;
  final String type;
  final String? customName;
  final String fileName;
  final String storagePath;
  final String? contentType;
  final DateTime expiryDate;
  final DateTime? uploadedAt;

  const PetDocumentRecord({
    required this.id,
    required this.petId,
    required this.ownerId,
    required this.type,
    required this.fileName,
    required this.storagePath,
    required this.expiryDate,
    this.customName,
    this.contentType,
    this.uploadedAt,
  });

  factory PetDocumentRecord.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>? ?? {});

    DateTime expiryDate = DateTime.now();
    final rawExpiry = data['expiryDate'];
    if (rawExpiry is Timestamp) {
      expiryDate = rawExpiry.toDate();
    }

    DateTime? uploadedAt;
    final rawUploaded = data['uploadedAt'];
    if (rawUploaded is Timestamp) {
      uploadedAt = rawUploaded.toDate();
    }

    return PetDocumentRecord(
      id: doc.id,
      petId: (data['petId'] ?? '') as String,
      ownerId: (data['ownerId'] ?? '') as String,
      type: (data['type'] ?? 'other') as String,
      customName: (data['customName'] as String?)?.trim(),
      fileName: (data['fileName'] ?? 'Document') as String,
      storagePath: (data['storagePath'] ?? '') as String,
      contentType: (data['contentType'] as String?)?.trim(),
      expiryDate: expiryDate,
      uploadedAt: uploadedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'petId': petId,
      'ownerId': ownerId,
      'type': type,
      if (customName != null && customName!.trim().isNotEmpty)
        'customName': customName!.trim(),
      'fileName': fileName,
      'storagePath': storagePath,
      if (contentType != null && contentType!.trim().isNotEmpty)
        'contentType': contentType!.trim(),
      'expiryDate': Timestamp.fromDate(expiryDate),
      'uploadedAt': uploadedAt != null
          ? Timestamp.fromDate(uploadedAt!)
          : FieldValue.serverTimestamp(),
    };
  }
}
