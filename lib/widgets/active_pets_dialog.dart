import 'package:flutter/material.dart';

class ActivePetsDialog extends StatelessWidget {
  final List<Map<String, dynamic>> pets;
  final void Function(String ownerId, String petId)? onFavoriteToggle;
  final Set<String> favoritePetIds;
  final String? currentUserId;

  const ActivePetsDialog({
    Key? key,
    required this.pets,
    this.onFavoriteToggle,
    this.favoritePetIds = const {},
    this.currentUserId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 24),
      title: const Text("Pets in Park"),
      content: SizedBox(
        width: 420,
        height: 500,
        child: pets.isEmpty
            ? const Center(child: Text("No pets currently checked in."))
            : ListView.separated(
                itemCount: pets.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (ctx, i) {
                  final pet = pets[i];
                  final ownerId = pet['ownerId'] as String? ?? '';
                  final petId = pet['petId'] as String? ?? '';
                  final petName = pet['petName'] as String? ?? '';
                  final petPhoto = pet['petPhotoUrl'] as String? ?? '';
                  final checkIn = pet['checkInTime'] as String? ?? '';
                  final mine = (ownerId == currentUserId);

                  return ListTile(
                    leading:
                        CircleAvatar(backgroundImage: NetworkImage(petPhoto)),
                    title: Text(petName),
                    subtitle: Text(mine
                        ? "Your pet – Checked in at $checkIn"
                        : "Checked in at $checkIn"),
                    trailing: mine
                        ? null
                        : IconButton(
                            icon: Icon(
                              favoritePetIds.contains(petId)
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: Colors.red,
                            ),
                            onPressed: onFavoriteToggle != null
                                ? () => onFavoriteToggle!(ownerId, petId)
                                : null,
                          ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    );
  }
}
