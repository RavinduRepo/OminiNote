import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/notebook_service.dart';

void main() async {
  // Ensures hardware bindings are initialized for rendering
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize notebook service
  final notebookService = NotebookService();
  await notebookService.init();

  runApp(const NoteApp());
}

class NoteApp extends StatelessWidget {
  const NoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stylus Notes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
