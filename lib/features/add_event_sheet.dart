import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_core/firebase_core.dart';

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

  void _logFirebaseContext() {
    final app = Firebase.app();
    final opts = app.options;
    debugPrint('FIREBASE projectId=${opts.projectId}');
    debugPrint('FIREBASE appId=${opts.appId}');
    debugPrint('AUTH uid=${FirebaseAuth.instance.currentUser?.uid}');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Add Event"),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: "Debug context",
            onPressed: _logFirebaseContext,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 120,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ===== Creating for park [park name] =====
                _parkNameBanner(cs),

                const SizedBox(height: 16),

                // Name
                TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: _inputDeco(
                    context,
                    label: "Event Name *",
                    hint: "e.g., Saturday Pack Walk",
                    icon: Icons.badge_outlined,
                  ),
                ),
                const SizedBox(height: 14),

                // Description
                TextField(
                  controller: _descCtrl,
                  maxLines: 4,
                  decoration: _inputDeco(
                    context,
                    label: "Description",
                    hint: "Add details, rules, or notes",
                    icon: Icons.notes_outlined,
                  ),
                ),
                const SizedBox(height: 18),

                _sectionHeader(context, "Recurrence"),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _recurrence,
                  decoration: _dropdownDeco(context, "Recurrence"),
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
                        : "Date: ${DateFormat.yMMMEd().format(_oneTimeDate!)}",
                    onPick: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        builder: _pickerTheme,
                      );
                      if (d != null) setState(() => _oneTimeDate = d);
                    },
                  ),

                if (_recurrence == "Weekly")
                  DropdownButtonFormField<String>(
                    value: _weekday,
                    decoration: _dropdownDeco(context, "Select Day of Week"),
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
                        : "Day of month: ${DateFormat.d().format(_monthlyDate!)}",
                    onPick: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        builder: _pickerTheme,
                      );
                      if (d != null) setState(() => _monthlyDate = d);
                    },
                  ),

                const SizedBox(height: 18),

                _sectionHeader(context, "Time"),
                const SizedBox(height: 8),

                // ===== Redesigned time card (same behavior) =====
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Column(
                    children: [
                      _timeRow(
                        label: _start == null
                            ? "No start time selected"
                            : "Start: ${_start!.format(context)}",
                        onPick: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.now(),
                            builder: (ctx, child) => Theme(
                              data: Theme.of(ctx),
                              child: child!,
                            ),
                          );
                          if (t != null) setState(() => _start = t);
                        },
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      _timeRow(
                        label: _end == null
                            ? "No end time selected"
                            : "End: ${_end!.format(context)}",
                        onPick: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.now(),
                            builder: (ctx, child) => Theme(
                              data: Theme.of(ctx),
                              child: child!,
                            ),
                          );
                          if (t != null) setState(() => _end = t);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),

                // Subtle hint if end <= start (visual only; logic unchanged)
                if (_start != null && _end != null)
                  Builder(builder: (context) {
                    final startMin = _start!.hour * 60 + _start!.minute;
                    final endMin = _end!.hour * 60 + _end!.minute;
                    if (endMin <= startMin) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: const [
                            Icon(Icons.error_outline, size: 16),
                            SizedBox(width: 6),
                            Text("End time should be after start time"),
                          ],
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }),
              ],
            ),
          ),
        ),
      ),

      // Sticky action bar (same actions)
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          decoration: BoxDecoration(
            color: cs.surface,
            border:
                Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Cancel"),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Add"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===== Park name banner (UI-only; no write logic touched) =====
  Widget _parkNameBanner(ColorScheme cs) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .snapshots(),
      builder: (context, snap) {
        final name = snap.data?.data()?['name'] as String?;
        final subtitle = name != null && name.trim().isNotEmpty
            ? "Creating for park $name"
            : "Creating for park @ (${widget.parkLatitude.toStringAsFixed(4)}, ${widget.parkLongitude.toStringAsFixed(4)})";

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.park_rounded,
                  size: 20, color: cs.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subtitle,
                  style: TextStyle(
                    color: cs.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ------- Styled helpers (same signatures) -------
  Widget _dateRow({required String label, required VoidCallback onPick}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.event_outlined),
            label: const Text("Select"),
          ),
        ],
      ),
    );
  }

  Widget _timeRow({required String label, required VoidCallback onPick}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.schedule_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(label)),
              ],
            ),
          ),
          TextButton(
            onPressed: onPick,
            child: const Text("Select"),
          ),
        ],
      ),
    );
  }

  // ------- Original submit logic untouched -------
  Future<void> _submit() async {
    _logFirebaseContext();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _toast("Please sign in to add an event.");
      return;
    }

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
      // Daily or Weekly
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
      'startDateTime': Timestamp.fromDate(startDt),
      'endDateTime': Timestamp.fromDate(endDt),
      'recurrence': _recurrence,
      if (_recurrence == "Weekly") 'weekday': _weekday,
      if (_recurrence == "One Time")
        'eventDate': Timestamp.fromDate(_oneTimeDate!),
      if (_recurrence == "Monthly") 'eventDay': _monthlyDate!.day,
      'likes': <String>[],
      'createdBy': uid,
    };

    debugPrint(
        'Writing event to /parks/${widget.parkId}/events with keys: ${eventData.keys.toList()}');

    try {
      await FirebaseFirestore.instance
          .collection('parks')
          .doc(widget.parkId)
          .collection('events')
          .add(eventData);
    } on FirebaseException catch (e) {
      _toast('Add failed: ${e.message ?? e.code}');
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
    _toast("Event '$name' added");
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------- Styling helpers -------
  InputDecoration _inputDeco(BuildContext context,
      {required String label, required String hint, IconData? icon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  InputDecoration _dropdownDeco(BuildContext context, String label) {
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _pickerTheme(BuildContext context, Widget? child) {
    final color = Theme.of(context).colorScheme.primary;
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(primary: color),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: color),
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }
}
