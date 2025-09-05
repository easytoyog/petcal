// image_upload_util.dart
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class ImageUploadUtil {
  /// Returns the download URL, or null if the user cancels.
  static Future<String?> pickAndUploadPetPhoto(String petIdForStorage) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85, // compress a bit to speed up uploads
    );
    if (picked == null) return null;

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final file = File(picked.path);

    // Path must match your Storage rules: pets/<uid>/<anything>
    final path = 'pets/$uid/$petIdForStorage.jpg';
    final ref = FirebaseStorage.instance.ref().child(path);

    try {
      // Set metadata so the file serves as an image
      final meta = SettableMetadata(contentType: 'image/jpeg');

      // Helpful for debugging
      // ignore: avoid_print
      print('[Storage] Uploading to: $path  (size: ${await file.length()} bytes)');

      final taskSnapshot = await ref.putFile(file, meta);
      final url = await taskSnapshot.ref.getDownloadURL();

      // ignore: avoid_print
      print('[Storage] Upload success. URL: $url');
      return url;
    } on FirebaseException catch (e) {
      // Common codes: 'unauthorized' (rules/App Check), 'canceled', 'unknown'
      // ignore: avoid_print
      print('[Storage] Upload failed: ${e.code} - ${e.message}');
      rethrow; // or return null if you want to swallow errors
    } catch (e) {
      // ignore: avoid_print
      print('[Storage] Upload failed (non-Firebase): $e');
      rethrow;
    }
  }
}
