import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class UploadedPetDocument {
  final String fileName;
  final String storagePath;
  final String? contentType;

  const UploadedPetDocument({
    required this.fileName,
    required this.storagePath,
    this.contentType,
  });
}

enum PetDocumentPickerSource {
  photoLibrary,
  files,
}

class DocumentUploadUtil {
  static const List<String> allowedExtensions = [
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'heic',
    'webp',
  ];

  static Future<UploadedPetDocument?> pickAndUploadPetDocument({
    required String petId,
    required String documentId,
    required PetDocumentPickerSource source,
  }) async {
    switch (source) {
      case PetDocumentPickerSource.photoLibrary:
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 95,
        );
        if (picked == null) return null;

        final bytes = await picked.readAsBytes();
        if (bytes.isEmpty) {
          throw Exception('Could not read the selected photo.');
        }

        final fileName = picked.name.isEmpty ? 'document.jpg' : picked.name;
        return _uploadBytes(
          petId: petId,
          documentId: documentId,
          fileName: fileName,
          bytes: bytes,
        );

      case PetDocumentPickerSource.files:
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: allowedExtensions,
          withData: true,
        );

        if (picked == null || picked.files.isEmpty) return null;

        final file = picked.files.single;
        final Uint8List? bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Could not read the selected file.');
        }

        return _uploadBytes(
          petId: petId,
          documentId: documentId,
          fileName: file.name,
          bytes: bytes,
        );
    }
  }

  static Future<UploadedPetDocument> _uploadBytes({
    required String petId,
    required String documentId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw Exception('Please sign in to upload documents.');
    }

    final extension = _fileExtension(fileName);
    final suffix = extension.isEmpty ? '' : '.$extension';
    final storagePath = 'pet_documents/$uid/$petId/$documentId$suffix';
    final ref = FirebaseStorage.instance.ref().child(storagePath);

    final metadata = SettableMetadata(
      contentType: _contentTypeForExtension(extension),
      customMetadata: {
        'originalName': fileName,
        'petId': petId,
      },
    );

    await ref.putData(bytes, metadata);

    return UploadedPetDocument(
      fileName: fileName,
      storagePath: storagePath,
      contentType: metadata.contentType,
    );
  }

  static String _fileExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).trim().toLowerCase();
  }

  static String _contentTypeForExtension(String extension) {
    switch (extension) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
      case 'heic':
      case 'webp':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }
}
