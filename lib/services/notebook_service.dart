import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/notebook.dart';
import '../models/page.dart';
import '../models/stroke.dart';

class NotebookService {
  static final NotebookService _instance = NotebookService._internal();

  factory NotebookService() => _instance;

  NotebookService._internal();

  late Directory appDir;
  late File notebooksFile;

  Future<void> init() async {
    appDir = await getApplicationDocumentsDirectory();
    notebooksFile = File('${appDir.path}/notebooks.json');

    // Create notebooks file if it doesn't exist
    if (!await notebooksFile.exists()) {
      await notebooksFile.writeAsString(jsonEncode({}));
    }
  }

  /// Get all notebooks
  Future<List<Notebook>> getNotebooks() async {
    final content = await notebooksFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    return data.values
        .map((json) => Notebook.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get a specific notebook by ID
  Future<Notebook?> getNotebook(String id) async {
    final notebooks = await getNotebooks();
    try {
      return notebooks.firstWhere((n) => n.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Create a new notebook
  Future<Notebook> createNotebook(String name) async {
    final notebook = Notebook(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
    );

    final content = await notebooksFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    data[notebook.id] = notebook.toJson();
    await notebooksFile.writeAsString(jsonEncode(data));

    return notebook;
  }

  /// Delete a notebook and all its pages
  Future<void> deleteNotebook(String notebookId) async {
    final content = await notebooksFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    data.remove(notebookId);
    await notebooksFile.writeAsString(jsonEncode(data));

    // Delete pages directory
    final pagesDir = Directory('${appDir.path}/notebooks/$notebookId');
    if (await pagesDir.exists()) {
      await pagesDir.delete(recursive: true);
    }
  }

  /// Get all pages for a notebook with their strokes
  Future<List<Page>> getPages(String notebookId) async {
    final pagesDir = Directory('${appDir.path}/notebooks/$notebookId');

    if (!await pagesDir.exists()) {
      return [];
    }

    final files = await pagesDir.list().toList();
    final pages = <Page>[];

    for (var file in files) {
      if (file is File &&
          file.path.endsWith('.json') &&
          !file.path.contains('_strokes')) {
        final content = await file.readAsString();
        var page = Page.fromJson(jsonDecode(content) as Map<String, dynamic>);

        // Load strokes if they exist
        final strokesFile = File(page.getStrokesFilePath(appDir.path));
        if (await strokesFile.exists()) {
          final strokesContent = await strokesFile.readAsString();
          final strokesList = List<Map<String, dynamic>>.from(
            jsonDecode(strokesContent) as List,
          );
          final strokes = strokesList.map((s) => Stroke.fromJson(s)).toList();
          page = page.copyWith(strokes: strokes);
        }

        pages.add(page);
      }
    }

    // Sort by creation date
    pages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return pages;
  }

  /// Get a specific page with its strokes
  Future<Page?> getPage(String notebookId, String pageId) async {
    final pageFile = File('${appDir.path}/notebooks/$notebookId/$pageId.json');

    if (!await pageFile.exists()) {
      return null;
    }

    final content = await pageFile.readAsString();
    final page = Page.fromJson(jsonDecode(content) as Map<String, dynamic>);

    // Load strokes if they exist
    final strokesFile = File(page.getStrokesFilePath(appDir.path));
    if (await strokesFile.exists()) {
      final strokesContent = await strokesFile.readAsString();
      final strokesList = List<Map<String, dynamic>>.from(
        jsonDecode(strokesContent) as List,
      );
      final strokes = strokesList.map((s) => Stroke.fromJson(s)).toList();
      return page.copyWith(strokes: strokes);
    }

    return page;
  }

  /// Create a new page
  Future<Page> createPage(
    String notebookId,
    String name, {
    String? pdfPath,
  }) async {
    final pageId = DateTime.now().millisecondsSinceEpoch.toString();
    final page = Page(
      id: pageId,
      notebookId: notebookId,
      name: name,
      createdAt: DateTime.now(),
      pdfPath: pdfPath,
    );

    // Create pages directory if it doesn't exist
    final pagesDir = Directory('${appDir.path}/notebooks/$notebookId');
    if (!await pagesDir.exists()) {
      await pagesDir.create(recursive: true);
    }

    // Save page metadata
    final pageFile = File('${pagesDir.path}/$pageId.json');
    await pageFile.writeAsString(jsonEncode(page.toJson()));

    // Update notebook's page list
    final notebooks = await getNotebooks();
    final notebook = notebooks.firstWhere((n) => n.id == notebookId);
    final updatedNotebook = notebook.copyWith(
      pageIds: [...notebook.pageIds, pageId],
    );

    final content = await notebooksFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    data[notebookId] = updatedNotebook.toJson();
    await notebooksFile.writeAsString(jsonEncode(data));

    return page;
  }

  /// Delete a page and its strokes
  Future<void> deletePage(String notebookId, String pageId) async {
    final pageFile = File('${appDir.path}/notebooks/$notebookId/$pageId.json');
    final strokesFile = File(
      '${appDir.path}/notebooks/$notebookId/${pageId}_strokes.json',
    );

    if (await pageFile.exists()) {
      await pageFile.delete();
    }
    if (await strokesFile.exists()) {
      await strokesFile.delete();
    }

    // Update notebook's page list
    final notebooks = await getNotebooks();
    final notebook = notebooks.firstWhere((n) => n.id == notebookId);
    final updatedNotebook = notebook.copyWith(
      pageIds: notebook.pageIds.where((id) => id != pageId).toList(),
    );

    final content = await notebooksFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    data[notebookId] = updatedNotebook.toJson();
    await notebooksFile.writeAsString(jsonEncode(data));
  }

  /// Update page with strokes (persistence)
  Future<void> updatePage(Page page) async {
    final pageFile = File(
      '${appDir.path}/notebooks/${page.notebookId}/${page.id}.json',
    );

    // Save page metadata (without strokes)
    final pageData = page.toJson();
    pageData.remove('strokes'); // Don't store strokes in page metadata
    await pageFile.writeAsString(jsonEncode(pageData));

    // Save strokes separately
    final pagesDir = Directory('${appDir.path}/notebooks/${page.notebookId}');
    if (!await pagesDir.exists()) {
      await pagesDir.create(recursive: true);
    }

    final strokesFile = File(page.getStrokesFilePath(appDir.path));
    final strokesData = page.strokes.map((s) => s.toJson()).toList();
    await strokesFile.writeAsString(jsonEncode(strokesData));
  }
}
