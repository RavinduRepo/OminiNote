import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../models/page.dart' as page_model;
import '../services/notebook_service.dart';
import 'page_screen.dart';

class NotebookScreen extends StatefulWidget {
  final Notebook notebook;

  const NotebookScreen({super.key, required this.notebook});

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  final _notebookService = NotebookService();
  late Future<List<page_model.Page>> _pagesFuture;

  @override
  void initState() {
    super.initState();
    _loadPages();
  }

  void _loadPages() {
    _pagesFuture = _notebookService.getPages(widget.notebook.id);
  }

  void _createPage({String? pdfPath}) async {
    final controller = TextEditingController();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2E2E3E),
        title: const Text('New Page', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Page name',
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
                await _notebookService.createPage(
                  widget.notebook.id,
                  controller.text,
                  pdfPath: pdfPath,
                );
                if (mounted) {
                  Navigator.pop(context);
                  setState(() => _loadPages());
                }
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _pickPdfAndCreatePage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null && result.files.single.path != null) {
      _createPage(pdfPath: result.files.single.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: Text(
          widget.notebook.name,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        backgroundColor: const Color(0xFF181825),
        elevation: 0,
      ),
      body: FutureBuilder<List<page_model.Page>>(
        future: _pagesFuture,
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

          final pages = snapshot.data ?? [];

          if (pages.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.description, size: 64, color: Colors.grey[700]),
                  const SizedBox(height: 16),
                  Text(
                    'No pages yet',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                  const SizedBox(height: 32),
                  Column(
                    children: [
                      ElevatedButton(
                        onPressed: () => _createPage(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                        child: const Text(
                          'Empty Page',
                          style: TextStyle(color: Colors.black),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _pickPdfAndCreatePage,
                        label: const Text('Page with PDF'),
                        icon: const Icon(Icons.description),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: pages.length,
            itemBuilder: (context, index) {
              final page = pages[index];
              return Card(
                color: const Color(0xFF2E2E3E),
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListTile(
                  leading: Icon(
                    page.pdfPath != null ? Icons.picture_as_pdf : Icons.edit,
                    color: Colors.white,
                  ),
                  title: Text(
                    page.name,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  subtitle: Text(
                    page.pdfPath != null ? 'With PDF' : 'Empty page',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  trailing: PopupMenuButton(
                    color: const Color(0xFF2E2E3E),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        onTap: () async {
                          await _notebookService.deletePage(
                            widget.notebook.id,
                            page.id,
                          );
                          setState(() => _loadPages());
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
                        builder: (context) => PageScreen(page: page),
                      ),
                    ).then((_) => setState(() => _loadPages()));
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'pdf_fab',
            onPressed: _pickPdfAndCreatePage,
            backgroundColor: Colors.white,
            child: const Icon(Icons.picture_as_pdf, color: Colors.black),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'empty_fab',
            onPressed: () => _createPage(),
            backgroundColor: Colors.white,
            child: const Icon(Icons.add, color: Colors.black),
          ),
        ],
      ),
    );
  }
}
