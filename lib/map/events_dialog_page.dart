import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pet_calendar/models/park_event.dart';

class EventsDialogPage extends StatefulWidget {
  final String parkId;
  final double parkLatitude;
  final double parkLongitude;

  const EventsDialogPage({
    Key? key,
    required this.parkId,
    required this.parkLatitude,
    required this.parkLongitude,
  }) : super(key: key);

  @override
  _EventsDialogPageState createState() => _EventsDialogPageState();
}

class _EventsDialogPageState extends State<EventsDialogPage> {
  bool _isLoading = true;
  List<ParkEvent> _events = [];

  @override
  void initState() {
    super.initState();
    _fetchEvents();
  }

  Future<void> _fetchEvents() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('events')
          .get();
      final events = snapshot.docs
          .map((doc) => ParkEvent.fromFirestore(doc))
          .toList();
      setState(() {
        _events = events;
      });
    } catch (e) {
      print("Error fetching events: $e");
    }
    setState(() {
      _isLoading = false;
    });
  }

  /// Opens the Add Event dialog. (You can either push a new route or show a dialog.)
  void _openAddEventDialog() {
    // For this example, we'll push a new route.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddEventPage(
          parkId: widget.parkId,
          parkLatitude: widget.parkLatitude,
          parkLongitude: widget.parkLongitude,
        ),
        fullscreenDialog: true,
      ),
    ).then((_) {
      // Refresh events when returning.
      _fetchEvents();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Events at this Park"),
        backgroundColor: Colors.tealAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _openAddEventDialog,
            tooltip: "Add Event",
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchEvents,
              child: ListView.builder(
                itemCount: _events.length,
                itemBuilder: (context, index) {
                  final event = _events[index];
                  return ListTile(
                    title: Text(event.name),
                    subtitle: Text(
                        "Starts: ${event.startDateTime.toLocal()}\nEnds: ${event.endDateTime.toLocal()}\nLikes: ${event.likes.length}\nRecurrence: ${event.recurrence}"),
                  );
                },
              ),
            ),
    );
  }
}

/// AddEventPage for adding a new event.
class AddEventPage extends StatefulWidget {
  final String parkId;
  final double parkLatitude;
  final double parkLongitude;

  const AddEventPage({
    Key? key,
    required this.parkId,
    required this.parkLatitude,
    required this.parkLongitude,
  }) : super(key: key);

  @override
  _AddEventPageState createState() => _AddEventPageState();
}

class _AddEventPageState extends State<AddEventPage> {
  final eventNameController = TextEditingController();
  DateTime? startDateTime;
  DateTime? endDateTime;
  String recurrence = "None";
  String? errorMessage;

  Future<DateTime?> _showDateTimePicker(BuildContext context) async {
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null) return null;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  void _saveEvent() async {
    if (eventNameController.text.trim().isEmpty || startDateTime == null || endDateTime == null) {
      setState(() {
        errorMessage = "Please fill out all required fields.";
      });
      return;
    }
    final newEventId = FirebaseFirestore.instance
        .collection('parks')
        .doc(widget.parkId)
        .collection('events')
        .doc()
        .id;
    final newEvent = ParkEvent(
      id: newEventId,
      parkId: widget.parkId,
      name: eventNameController.text.trim(),
      startDateTime: startDateTime!,
      endDateTime: endDateTime!,
      likes: [],
      createdBy: FirebaseAuth.instance.currentUser!.uid,
      parkLatitude: widget.parkLatitude,
      parkLongitude: widget.parkLongitude,
      recurrence: recurrence.toLowerCase(),
    );
    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('events')
          .doc(newEventId)
          .set(newEvent.toMap());
      Navigator.of(context).pop(); // Close the AddEventPage
    } catch (e) {
      print("Error saving event: $e");
      setState(() {
        errorMessage = "Error saving event. Please try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Add Event"),
        backgroundColor: Colors.tealAccent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: eventNameController,
                decoration: const InputDecoration(
                  labelText: "Event Name *",
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                title: Text(startDateTime == null
                    ? "Select Start Date & Time *"
                    : "Start: ${startDateTime!.toLocal()}"),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await _showDateTimePicker(context);
                  if (picked != null) {
                    setState(() {
                      startDateTime = picked;
                      errorMessage = null;
                    });
                  }
                },
              ),
              ListTile(
                title: Text(endDateTime == null
                    ? "Select End Date & Time *"
                    : "End: ${endDateTime!.toLocal()}"),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await _showDateTimePicker(context);
                  if (picked != null) {
                    setState(() {
                      endDateTime = picked;
                      errorMessage = null;
                    });
                  }
                },
              ),
              DropdownButtonFormField<String>(
                value: recurrence,
                decoration: const InputDecoration(labelText: "Recurrence"),
                items: ["None", "Daily", "Weekly", "Monthly"].map((value) {
                  return DropdownMenuItem(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      recurrence = value;
                    });
                  }
                },
              ),
              if (errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saveEvent,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                ),
                child: const Text("Save Event"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
