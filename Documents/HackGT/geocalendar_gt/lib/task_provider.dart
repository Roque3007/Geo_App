import 'package:flutter/foundation.dart';
import 'package:geocalendar_gt/task.dart';

class TaskProvider extends ChangeNotifier {
  final List<Task> _tasks = [];

  List<Task> get tasks => List.unmodifiable(_tasks);

  void addTask(Task t) {
    _tasks.add(t);
    notifyListeners();
  }

  void clear() {
    _tasks.clear();
    notifyListeners();
  }

  void updateTask(
    String id, {
    String? title,
    String? locationText,
    double? lat,
    double? lng,
  }) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final old = _tasks[idx];
    final updated = Task(
      id: old.id,
      title: title ?? old.title,
      locationText: locationText ?? old.locationText,
      lat: lat ?? old.lat,
      lng: lng ?? old.lng,
    );
    _tasks[idx] = updated;
    notifyListeners();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }
}
