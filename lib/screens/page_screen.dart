import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/page.dart' as page_model;
import '../models/stroke.dart';
import '../painters/drawing_painter.dart';
import '../services/notebook_service.dart';

class PageScreen extends StatefulWidget {
  final page_model.Page page;

  const PageScreen({super.key, required this.page});

  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  late List<Stroke> _strokes;
  Stroke? _currentStroke;
  final PdfViewerController _pdfController = PdfViewerController();
  Color _currentColor = Colors.white;
  double _currentStrokeSize = 4.0;
  final _notebookService = NotebookService();
  late page_model.Page _currentPage;
  bool _isStylusDrawing = false; // Track if stylus is actively drawing

  static const List<Color> _colorOptions = [
    Colors.white,
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.yellow,
    Colors.orange,
    Colors.purple,
    Colors.cyan,
  ];

  @override
  void initState() {
    super.initState();
    _currentPage = widget.page;
    _strokes = List.from(_currentPage.strokes);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.stylus) {
      _isStylusDrawing = true;
      final position = _transformPointerPosition(event.localPosition);
      setState(() {
        _currentStroke = Stroke(
          points: [PointVector(position.dx, position.dy, event.pressure)],
          color: _currentColor,
          strokeSize: _currentStrokeSize,
        );
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final stroke = _currentStroke; // Local variable for promotion
    if (event.kind == PointerDeviceKind.stylus && stroke != null) {
      final position = _transformPointerPosition(event.localPosition);
      setState(() {
        stroke.points.add(
          PointVector(position.dx, position.dy, event.pressure),
        );
      });
    }
  }

  /// Transform pointer coordinates from screen space to PDF space
  Offset _transformPointerPosition(Offset screenPosition) {
    try {
      // Try to get transform from controller
      // First check if controller has a valid value
      final controller = _pdfController;

      Matrix4 transform;
      try {
        transform = controller.value;
        // Check if transform is identity or invalid
        if (transform.isIdentity()) {
          return screenPosition;
        }
      } catch (e) {
        // Controller not ready yet
        return screenPosition;
      }

      final inverse = Matrix4.inverted(transform);

      // Apply the inverse transform manually using matrix multiplication
      final x = screenPosition.dx;
      final y = screenPosition.dy;

      final m = inverse.storage;
      if (m.length < 16) {
        return screenPosition;
      }

      final transformedX = m[0] * x + m[4] * y + m[12];
      final transformedY = m[1] * x + m[5] * y + m[13];

      return Offset(transformedX, transformedY);
    } catch (e) {
      // Any error, just return original position
      return screenPosition;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_currentStroke != null) {
      setState(() {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
      });

      _isStylusDrawing = false;

      // Save strokes to disk
      _currentPage = _currentPage.copyWith(strokes: _strokes);
      _notebookService.updatePage(_currentPage);
    }
  }

  /// Build the drawing overlay with stylus-only input
  Widget _buildDrawingOverlay(Matrix4? transform) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.stylus) {
          _onPointerDown(event);
        }
      },
      onPointerMove: (event) {
        if (event.kind == PointerDeviceKind.stylus) {
          _onPointerMove(event);
        }
      },
      onPointerUp: (event) {
        if (event.kind == PointerDeviceKind.stylus) {
          _onPointerUp(event);
        }
      },
      onPointerCancel: (event) {
        if (event.kind == PointerDeviceKind.stylus) {
          _onPointerUp(PointerUpEvent(pointer: event.pointer));
        }
      },
      child: IgnorePointer(
        ignoring: true,
        child: CustomPaint(
          painter: DrawingPainter(
            strokes: _strokes,
            currentStroke: _currentStroke,
            transform: transform,
          ),
          child: Container(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPdf =
        widget.page.pdfPath != null && widget.page.pdfPath!.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: Text(
          widget.page.name,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        backgroundColor: const Color(0xFF181825),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: () {
              if (_strokes.isNotEmpty) {
                setState(() => _strokes.removeLast());
                _currentPage = _currentPage.copyWith(strokes: _strokes);
                _notebookService.updatePage(_currentPage);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() => _strokes.clear());
              _currentPage = _currentPage.copyWith(strokes: _strokes);
              _notebookService.updatePage(_currentPage);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // PDF or Empty Canvas - disable scrolling when stylus is drawing
          if (hasPdf)
            AbsorbPointer(
              absorbing: _isStylusDrawing,
              child: PdfViewer.file(
                widget.page.pdfPath!,
                controller: _pdfController,
                params: const PdfViewerParams(
                  backgroundColor: Color(0xFF1E1E2E),
                ),
              ),
            )
          else
            Container(color: const Color(0xFF1E1E2E)),
          // Drawing Overlay - with Listener for stylus only
          Positioned.fill(
            child: hasPdf
                ? AnimatedBuilder(
                    animation: _pdfController,
                    builder: (context, child) {
                      Matrix4? transform;
                      try {
                        // Safely try to get the value.
                        // If the pdfrx controller isn't attached yet,
                        // it throws internally, and we safely catch it.
                        transform = _pdfController.value;
                      } catch (e) {
                        // Controller not ready, leave transform as null
                        transform = null;
                      }

                      return _buildDrawingOverlay(transform);
                    },
                  )
                : _buildDrawingOverlay(null),
          ),
          // Controls Panel
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF2E2E3E).withOpacity(0.95),
                border: const Border(
                  top: BorderSide(color: Color(0xFF3C3C54), width: 1),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Color picker
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const Text(
                          'Color: ',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                        ...List.generate(
                          _colorOptions.length,
                          (index) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: GestureDetector(
                              onTap: () => setState(
                                () => _currentColor = _colorOptions[index],
                              ),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: _colorOptions[index],
                                  border: Border.all(
                                    color: _currentColor == _colorOptions[index]
                                        ? Colors.white
                                        : Colors.grey[700]!,
                                    width: _currentColor == _colorOptions[index]
                                        ? 3
                                        : 1,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Stroke size slider
                  Row(
                    children: [
                      const Text(
                        'Size: ',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _currentStrokeSize,
                          min: 1.0,
                          max: 20.0,
                          divisions: 19,
                          label: _currentStrokeSize.toStringAsFixed(1),
                          onChanged: (value) =>
                              setState(() => _currentStrokeSize = value),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _currentStrokeSize.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
