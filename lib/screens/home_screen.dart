import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../services/notebook_service.dart';
import 'notebook_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _notebookService = NotebookService();
  late Future<List<Notebook>> _notebooksFuture;

  @override
  void initState() {
    super.initState();
    _loadNotebooks();
  }

  void _loadNotebooks() {
    _notebooksFuture = _notebookService.getNotebooks();
  }

  void _createNotebook() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2E2E3E),
        title: const Text(
          'New Notebook',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Notebook name',
            hintStyle: TextStyle(color: Colors.grey[600]),
            border: OutlineInputBorder(
              borderSide: const BorderSide(color: Color(0xFF3C3C54)),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: Color(0xFF3C3C54)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: Colors.white),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await _notebookService.createNotebook(controller.text);
                if (mounted) {
                  Navigator.pop(context);
                  setState(() => _loadNotebooks());
                }
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text(
          'Notebooks',
          style: TextStyle(fontFamily: 'monospace'),
        ),
        backgroundColor: const Color(0xFF181825),
        elevation: 0,
      ),
      body: FutureBuilder<List<Notebook>>(
        future: _notebooksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.white),
              ),
            );
          }

          final notebooks = snapshot.data ?? [];

          if (notebooks.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.note, size: 64, color: Colors.grey[700]),
                  const SizedBox(height: 16),
                  Text(
                    'No notebooks yet',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _createNotebook,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                    ),
                    child: const Text(
                      'Create Notebook',
                      style: TextStyle(color: Colors.black),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: notebooks.length,
            itemBuilder: (context, index) {
              final notebook = notebooks[index];
              return Card(
                color: const Color(0xFF2E2E3E),
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListTile(
                  leading: const Icon(Icons.note, color: Colors.white),
                  title: Text(
                    notebook.name,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  subtitle: Text(
                    '${notebook.pageIds.length} pages',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  trailing: PopupMenuButton(
                    color: const Color(0xFF2E2E3E),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        onTap: () async {
                          await _notebookService.deleteNotebook(notebook.id);
                          setState(() => _loadNotebooks());
                        },
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            NotebookScreen(notebook: notebook),
                      ),
                    ).then((_) => setState(() => _loadNotebooks()));
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNotebook,
        backgroundColor: Colors.white,
        child: const Icon(Icons.add, color: Colors.black),
      ),
    );
  }
}
