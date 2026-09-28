import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A photo stored as base64 text, decoded once rather than on every build.
///
/// `Image.memory(base64Decode(...))` in a build method hands Flutter a new
/// byte list each rebuild, and a MemoryImage is only the same image as the
/// same list - so the photo is reloaded from scratch every time, and shows
/// nothing while it loads. The dashboards rebuild every second for their
/// countdowns, which made proof photos blink.
class Base64Image extends StatefulWidget {
  const Base64Image(
    this.base64Image, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
  });

  final String base64Image;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<Base64Image> createState() => _Base64ImageState();
}

class _Base64ImageState extends State<Base64Image> {
  late Uint8List _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = base64Decode(widget.base64Image);
  }

  @override
  void didUpdateWidget(Base64Image oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.base64Image != widget.base64Image) {
      _bytes = base64Decode(widget.base64Image);
    }
  }

  @override
  Widget build(BuildContext context) => Image.memory(
        _bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
        // Should the photo change, keep the old one up until the new one is
        // ready rather than showing nothing.
        gaplessPlayback: true,
      );
}
