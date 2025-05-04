import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// A utility class that handles picking and uploading an image to Firebase Storage.
/// In this example, we store images in the path "pets/<petId>.jpg", but you can customize.
class ImageUploadUtil {
  // Make this class non-instantiable
  ImageUploadUtil._();

  /// Prompts the user to pick an image from the gallery, calls [onLocalImagePicked]
  /// with the local file path immediately so the UI can update, then uploads the image
  /// to Firebase Storage at "pets/<petId>.jpg" and returns the download URL.
  ///
  /// Returns `null` if the user cancels or if an error occurs.
  /// [petId] is used to create a unique path in storage, e.g. "pets/petId.jpg".
  static Future<String?> pickAndUploadPetPhoto(
    String petId, {
    void Function(String localPath)? onLocalImagePicked,
  }) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile == null) {
        // User canceled the picker.
        return null;
      }

      // Immediately call the callback with the local file path so the UI can display the image.
      if (onLocalImagePicked != null) {
        onLocalImagePicked(pickedFile.path);
      }

      final file = File(pickedFile.path);

      // Reference your Firebase Storage bucket
      final storageRef = FirebaseStorage.instance
          .refFromURL("gs://pet-app-38a26.firebasestorage.app");

      // Define the storage path (e.g., "pets/<petId>.jpg")
      final petImagesRef = storageRef.child("pets/$petId.jpg");

      // Upload the file to Firebase Storage
      await petImagesRef.putFile(file);

      // Retrieve and return the download URL
      final downloadUrl = await petImagesRef.getDownloadURL();
      return downloadUrl;
    } catch (e) {
      print("Error picking or uploading image: $e");
      return null;
    }
  }
}
