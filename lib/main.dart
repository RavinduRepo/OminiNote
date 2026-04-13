import 'package:flutter/material.dart';
import 'screens/note_screen.dart';

void main() {
  // Ensures hardware bindings are initialized for rendering
  WidgetsFlutterBinding.ensureInitialized();
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
      home: const NoteScreen(),
    );
  }
}
