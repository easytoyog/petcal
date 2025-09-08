// image_upload_util.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

// Compression deps
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

class ImageUploadUtil {
  /// Compress an XFile to web-friendly JPEG bytes before upload.
  /// - maxSide: max width/height while keeping aspect ratio
  /// - quality: JPEG quality 1..100
  static Future<Uint8List> _compressForUpload(
    XFile xfile, {
    int maxSide = 1600,
    int quality = 80,
  }) async {
    // Web: pure-Dart path (no dart:io)
    if (kIsWeb) {
      final original = await xfile.readAsBytes();
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;

      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxSide)
          : img.copyResize(decoded, height: maxSide);

      return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    }

    // Mobile: try native compressor first (fast, handles HEIC)
    try {
      final native = await FlutterImageCompress.compressWithFile(
        xfile.path,
        minWidth: maxSide,
        minHeight: maxSide,
        quality: quality,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (native != null) return native;
    } catch (_) {
      // fall through to pure-Dart
    }

    // Fallback: pure-Dart compression
    final original = await File(xfile.path).readAsBytes();
    final decoded = img.decodeImage(original);
    if (decoded == null) return original;

    final resized = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide)
        : img.copyResize(decoded, height: maxSide);

    return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
  }

  /// Pick a pet photo, compress it, and upload to:
  ///   pets/<uid>/<petIdForStorage>.jpg
  /// Returns the download URL, or null if the user cancels.
  static Future<String?> pickAndUploadPetPhoto(String petIdForStorage) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 100, // we'll do our own compression
    );
    if (picked == null) return null;

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final path = 'pets/$uid/$petIdForStorage.jpg';
    final ref = FirebaseStorage.instance.ref().child(path);

    try {
      final bytes = await _compressForUpload(picked, maxSide: 1600, quality: 80);
      final meta = SettableMetadata(contentType: 'image/jpeg');

      // ignore: avoid_print
      print('[Storage] Uploading to: $path  (compressed: ${bytes.lengthInBytes} bytes)');
      final taskSnapshot = await ref.putData(bytes, meta);
      final url = await taskSnapshot.ref.getDownloadURL();
      // ignore: avoid_print
      print('[Storage] Upload success. URL: $url');
      return url;
    } on FirebaseException catch (e) {
      // ignore: avoid_print
      print('[Storage] Upload failed: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      // ignore: avoid_print
      print('[Storage] Upload failed (non-Firebase): $e');
      rethrow;
    }
  }

  // ========= NEW: service image helpers =========

  /// Upload ONE service image (already picked) under:
  ///   service_images/<uid>/<timestamp>_<size>.jpg
  /// Returns the download URL.
  static Future<String> uploadServiceImageFromXFile(
    XFile xfile, {
    int maxSide = 1600,
    int quality = 80,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // 1) compress
    final bytes = await _compressForUpload(xfile, maxSide: maxSide, quality: quality);

    // 2) path + metadata
    final filename = '${DateTime.now().millisecondsSinceEpoch}_${bytes.lengthInBytes}.jpg';
    final path = 'service_images/$uid/$filename';
    final ref = FirebaseStorage.instance.ref(path);
    final meta = SettableMetadata(contentType: 'image/jpeg');

    // 3) upload
    // ignore: avoid_print
    print('[Storage] Uploading service image -> $path (${bytes.lengthInBytes} bytes)');
    final snap = await ref.putData(bytes, meta);
    final url = await snap.ref.getDownloadURL();
    // ignore: avoid_print
    print('[Storage] Service image uploaded: $url');
    return url;
  }

  /// Upload multiple service images and return their download URLs.
  static Future<List<String>> uploadServiceImages(
    List<XFile> files, {
    int maxSide = 1600,
    int quality = 80,
  }) async {
    final urls = <String>[];
    for (final f in files) {
      urls.add(await uploadServiceImageFromXFile(f, maxSide: maxSide, quality: quality));
    }
    return urls;
  }
}
