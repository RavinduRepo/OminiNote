import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/stroke.dart';
import '../painters/drawing_painter.dart';

class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key});

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

/// Overlay that only captures stylus events, allowing all other input to pass through
class _StylusDrawingOverlay extends StatelessWidget {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerUpEvent> onPointerUp;

  const _StylusDrawingOverlay({
    required this.strokes,
    required this.currentStroke,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true, // Don't intercept any input
        child: CustomPaint(
          painter: DrawingPainter(
            strokes: strokes,
            currentStroke: currentStroke,
          ),
          child: Container(),
        ),
      ),
    );
  }
}

class _NoteScreenState extends State<NoteScreen> {
  final List<Stroke> _strokes = [];
  Stroke? _currentStroke;
  final PdfViewerController _pdfController = PdfViewerController();
  Color _currentColor = Colors.white;
  double _currentStrokeSize = 4.0;

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

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.stylus) {
      setState(() {
        _currentStroke = Stroke(
          points: [
            PointVector(
              event.localPosition.dx,
              event.localPosition.dy,
              event.pressure,
            ),
          ],
          color: _currentColor,
          strokeSize: _currentStrokeSize,
        );
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.stylus && _currentStroke != null) {
      setState(() {
        _currentStroke!.points.add(
          PointVector(
            event.localPosition.dx,
            event.localPosition.dy,
            event.pressure,
          ),
        );
      });
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_currentStroke != null) {
      setState(() {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text(
          'Workspace',
          style: TextStyle(fontFamily: 'monospace'),
        ),
        backgroundColor: const Color(0xFF181825),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: () {
              if (_strokes.isNotEmpty) setState(() => _strokes.removeLast());
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _strokes.clear()),
          ),
        ],
      ),
      body: Listener(
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.stylus) _onPointerDown(event);
        },
        onPointerMove: (event) {
          if (event.kind == PointerDeviceKind.stylus) _onPointerMove(event);
        },
        onPointerUp: (event) {
          if (event.kind == PointerDeviceKind.stylus) _onPointerUp(event);
        },
        onPointerCancel: (event) {
          if (event.kind == PointerDeviceKind.stylus) {
            _onPointerUp(PointerUpEvent(pointer: event.pointer));
          }
        },
        child: Stack(
          children: [
            PdfViewer.asset(
              'assets/sample.pdf',
              controller: _pdfController,
              params: const PdfViewerParams(backgroundColor: Color(0xFF1E1E2E)),
            ),
            _StylusDrawingOverlay(
              strokes: _strokes,
              currentStroke: _currentStroke,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
            ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
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
                                      color:
                                          _currentColor == _colorOptions[index]
                                          ? Colors.white
                                          : Colors.grey[700]!,
                                      width:
                                          _currentColor == _colorOptions[index]
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
      ),
    );
  }
}
