import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AddEventSheet extends StatefulWidget {
  final String parkId;
  final double parkLatitude;
  final double parkLongitude;

  const AddEventSheet({
    Key? key,
    required this.parkId,
    required this.parkLatitude,
    required this.parkLongitude,
  }) : super(key: key);

  @override
  State<AddEventSheet> createState() => _AddEventSheetState();
}

class _AddEventSheetState extends State<AddEventSheet> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  String? _recurrence = "One Time";
  DateTime? _oneTimeDate;
  DateTime? _monthlyDate;
  String? _weekday;
  TimeOfDay? _start;
  TimeOfDay? _end;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4,
                width: 48,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const Text("Add Event",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: "Event Name *",
                  hintText: "Enter event name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _descCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: "Description",
                  hintText: "Enter event description",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _recurrence,
                decoration: const InputDecoration(
                  labelText: "Recurrence",
                  border: OutlineInputBorder(),
                ),
                items: const ["One Time", "Daily", "Weekly", "Monthly"]
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (val) => setState(() {
                  _recurrence = val;
                  _oneTimeDate = null;
                  _monthlyDate = null;
                  _weekday = null;
                }),
              ),
              const SizedBox(height: 16),
              if (_recurrence == "One Time")
                _dateRow(
                  label: _oneTimeDate == null
                      ? "No date selected"
                      : "Date: ${DateFormat.yMd().format(_oneTimeDate!)}",
                  onPick: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setState(() => _oneTimeDate = d);
                  },
                ),
              if (_recurrence == "Weekly")
                DropdownButtonFormField<String>(
                  value: _weekday,
                  decoration: const InputDecoration(
                    labelText: "Select Day of Week",
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    "Monday",
                    "Tuesday",
                    "Wednesday",
                    "Thursday",
                    "Friday",
                    "Saturday",
                    "Sunday"
                  ]
                      .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                      .toList(),
                  onChanged: (v) => setState(() => _weekday = v),
                ),
              if (_recurrence == "Monthly")
                _dateRow(
                  label: _monthlyDate == null
                      ? "No date selected"
                      : "Date: ${DateFormat.d().format(_monthlyDate!)}",
                  onPick: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setState(() => _monthlyDate = d);
                  },
                ),
              const SizedBox(height: 16),
              _timeRow(
                label: _start == null
                    ? "No start time selected"
                    : "Start: ${_start!.format(context)}",
                onPick: () async {
                  final t = await showTimePicker(
                      context: context, initialTime: TimeOfDay.now());
                  if (t != null) setState(() => _start = t);
                },
              ),
              _timeRow(
                label: _end == null
                    ? "No end time selected"
                    : "End: ${_end!.format(context)}",
                onPick: () async {
                  final t = await showTimePicker(
                      context: context, initialTime: TimeOfDay.now());
                  if (t != null) setState(() => _end = t);
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Cancel")),
                  const SizedBox(width: 12),
                  ElevatedButton(onPressed: _submit, child: const Text("Add")),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateRow({required String label, required VoidCallback onPick}) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        TextButton(onPressed: onPick, child: const Text("Select Date")),
      ],
    );
  }

  Widget _timeRow({required String label, required VoidCallback onPick}) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        TextButton(onPressed: onPick, child: const Text("Select Time")),
      ],
    );
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    if (name.isEmpty || _start == null || _end == null || _recurrence == null) {
      _toast("Please complete all required fields");
      return;
    }
    if (_recurrence == "One Time" && _oneTimeDate == null) {
      _toast("Please select a date for a one-time event");
      return;
    }
    if (_recurrence == "Weekly" && _weekday == null) {
      _toast("Please select a day for a weekly event");
      return;
    }
    if (_recurrence == "Monthly" && _monthlyDate == null) {
      _toast("Please select a date for a monthly event");
      return;
    }

    final now = DateTime.now();
    DateTime startDt, endDt;
    if (_recurrence == "One Time") {
      startDt = DateTime(_oneTimeDate!.year, _oneTimeDate!.month,
          _oneTimeDate!.day, _start!.hour, _start!.minute);
      endDt = DateTime(_oneTimeDate!.year, _oneTimeDate!.month,
          _oneTimeDate!.day, _end!.hour, _end!.minute);
    } else if (_recurrence == "Monthly") {
      startDt = DateTime(
          now.year, now.month, _monthlyDate!.day, _start!.hour, _start!.minute);
      endDt = DateTime(
          now.year, now.month, _monthlyDate!.day, _end!.hour, _end!.minute);
    } else {
      startDt =
          DateTime(now.year, now.month, now.day, _start!.hour, _start!.minute);
      endDt = DateTime(now.year, now.month, now.day, _end!.hour, _end!.minute);
    }

    if (!endDt.isAfter(startDt)) {
      _toast("End time must be after start time");
      return;
    }

    final eventData = <String, dynamic>{
      'parkId': widget.parkId,
      'parkLatitude': widget.parkLatitude,
      'parkLongitude': widget.parkLongitude,
      'name': name,
      'description': desc,
      'startDateTime': startDt,
      'endDateTime': endDt,
      'recurrence': _recurrence,
      'likes': [],
      'createdBy': FirebaseAuth.instance.currentUser?.uid ?? "",
      'createdAt': FieldValue.serverTimestamp(),
    };
    if (_recurrence == "Weekly") eventData['weekday'] = _weekday;
    if (_recurrence == "One Time") eventData['eventDate'] = _oneTimeDate;
    if (_recurrence == "Monthly") eventData['eventDay'] = _monthlyDate!.day;

    await FirebaseFirestore.instance
        .collection('parks')
        .doc(widget.parkId)
        .collection('events')
        .add(eventData);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Event '$name' added")));
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
