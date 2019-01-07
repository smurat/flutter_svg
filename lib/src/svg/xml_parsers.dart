import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path_drawing/path_drawing.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:xml/xml.dart';

import '../utilities/xml.dart';
import '../vector_drawable.dart';
import 'colors.dart';
import 'parsers.dart';

double _parseRawWidthHeight(String raw) {
  if (raw == '100%' || raw == '') {
    return double.infinity;
  }
  assert(() {
    final RegExp notDigits = RegExp(r'[^\d\.]');
    if (!raw.endsWith('px') && raw.contains(notDigits)) {
      print(
          'Warning: Flutter SVG only supports the following formats for `width` and `height` on the SVG root:\n'
          '  width="100%"\n'
          '  width="100px"\n'
          '  width="100" (where the number will be treated as pixels).\n'
          'The supplied value ($raw) will be discarded and treated as if it had not been specified.');
    }
    return true;
  }());
  return double.tryParse(raw.replaceAll('px', '')) ?? double.infinity;
}

/// Parses an SVG @viewBox attribute (e.g. 0 0 100 100) to a [Rect].
///
/// The [nullOk] parameter controls whether this function should throw if there is no
/// viewBox or width/height parameters.
///
/// The [respectWidthHeight] parameter specifies whether `width` and `height` attributes
/// on the root SVG element should be treated in accordance with the specification.
DrawableViewport parseViewBox(
  List<XmlAttribute> svg, {
  bool nullOk = false,
}) {
  final String viewBox = getAttribute(svg, 'viewBox');
  final String rawWidth = getAttribute(svg, 'width');
  final String rawHeight = getAttribute(svg, 'height');

  if (viewBox == '' && rawWidth == '' && rawHeight == '') {
    if (nullOk) {
      return null;
    }
    throw StateError('SVG did not specify dimensions\n\n'
        'The SVG library looks for a `viewBox` or `width` and `height` attribute '
        'to determine the viewport boundary of the SVG.  Note that these attributes, '
        'as with all SVG attributes, are case sensitive.\n'
        'During processing, the following attributes were found:\n'
        '  $svg');
  }

  final double width = _parseRawWidthHeight(rawWidth);
  final double height = _parseRawWidthHeight(rawHeight);

  if (viewBox == '') {
    return DrawableViewport(
      Size(width, height),
      Size(width, height),
    );
  }

  final List<String> parts = viewBox.split(RegExp(r'[ ,]+'));
  if (parts.length < 4) {
    throw StateError('viewBox element must be 4 elements long');
  }

  return DrawableViewport(
    Size(width, height),
    Size(
      double.parse(parts[2]),
      double.parse(parts[3]),
    ),
    viewBoxOffset: Offset(
      -double.parse(parts[0]),
      -double.parse(parts[1]),
    ),
  );
}

String buildUrlIri(List<XmlAttribute> attributes) =>
    'url(#${getAttribute(attributes, 'id')})';

const String emptyUrlIri = 'url(#)';

TileMode parseTileMode(List<XmlAttribute> attributes) {
  final String spreadMethod =
      getAttribute(attributes, 'spreadMethod', def: 'pad');
  switch (spreadMethod) {
    case 'pad':
      return TileMode.clamp;
    case 'repeat':
      return TileMode.repeated;
    case 'reflect':
      return TileMode.mirror;
    default:
      return TileMode.clamp;
  }
}

/// Parses an @stroke-dasharray attribute into a [CircularIntervalList]
///
/// Does not currently support percentages.
CircularIntervalList<double> parseDashArray(List<XmlAttribute> attributes) {
  final String rawDashArray = getAttribute(attributes, 'stroke-dasharray');
  if (rawDashArray == '') {
    return null;
  } else if (rawDashArray == 'none') {
    return DrawableStyle.emptyDashArray;
  }

  final List<String> parts = rawDashArray.split(RegExp(r'[ ,]+'));
  return CircularIntervalList<double>(
      parts.map((String part) => double.parse(part)).toList());
}

/// Parses a @stroke-dashoffset into a [DashOffset]
DashOffset parseDashOffset(List<XmlAttribute> attributes) {
  final String rawDashOffset = getAttribute(attributes, 'stroke-dashoffset');
  if (rawDashOffset == '') {
    return null;
  }

  if (rawDashOffset.endsWith('%')) {
    final double percentage =
        double.parse(rawDashOffset.substring(0, rawDashOffset.length - 1)) /
            100;
    return DashOffset.percentage(percentage);
  } else {
    return DashOffset.absolute(double.parse(rawDashOffset));
  }
}

/// Parses an @opacity value into a [double], clamped between 0..1.
double parseOpacity(List<XmlAttribute> attributes) {
  final String rawOpacity = getAttribute(attributes, 'opacity', def: null);
  if (rawOpacity != null) {
    return double.parse(rawOpacity).clamp(0.0, 1.0);
  }
  return null;
}

DrawablePaint _getDefinitionPaint(PaintingStyle paintingStyle, String iri,
    DrawableDefinitionServer definitions, Rect bounds,
    {double opacity}) {
  final Shader shader = definitions.getPaint(iri, bounds);
  if (shader == null) {
    FlutterError.onError(
      FlutterErrorDetails(
        exception: StateError('Failed to find definition for $iri'),
        context: 'in _getDefinitionPaint',
        library: 'SVG',
        informationCollector: (StringBuffer buff) {
          buff.writeln(
              'This library only supports <defs> that are defined ahead of their references. '
              'This error can be caused when the desired definition is defined after the element '
              'referring to it (e.g. at the end of the file), or defined in another file.');
          buff.writeln(
              'This error is treated as non-fatal, but your SVG file will likely not render as intended');
        },
      ),
    );
  }

  return DrawablePaint(
    paintingStyle,
    shader: shader,
    color: opacity != null ? Color.fromRGBO(255, 255, 255, opacity) : null,
  );
}

/// Parses a @stroke attribute into a [Paint].
DrawablePaint parseStroke(
  List<XmlAttribute> attributes,
  Rect bounds,
  DrawableDefinitionServer definitions,
  DrawablePaint parentStroke,
) {
  final String rawStroke = getAttribute(attributes, 'stroke');
  final String rawOpacity = getAttribute(attributes, 'stroke-opacity');

  final double opacity = rawOpacity == ''
      ? parentStroke?.color?.opacity ?? 1.0
      : double.parse(rawOpacity).clamp(0.0, 1.0);

  if (rawStroke.startsWith('url')) {
    return _getDefinitionPaint(
      PaintingStyle.stroke,
      rawStroke,
      definitions,
      bounds,
      opacity: opacity,
    );
  }
  if (rawStroke == '' && DrawablePaint.isEmpty(parentStroke)) {
    return null;
  }
  if (rawStroke == 'none') {
    return DrawablePaint.empty;
  }

  final String rawStrokeCap = getAttribute(attributes, 'stroke-linecap');
  final String rawLineJoin = getAttribute(attributes, 'stroke-linejoin');
  final String rawMiterLimit = getAttribute(attributes, 'stroke-miterlimit');
  final String rawStrokeWidth = getAttribute(attributes, 'stroke-width');

  final DrawablePaint paint = DrawablePaint(
    PaintingStyle.stroke,
    color: rawStroke == ''
        ? (parentStroke?.color ?? colorBlack).withOpacity(opacity)
        : parseColor(rawStroke).withOpacity(opacity),
    strokeCap: rawStrokeCap == 'null'
        ? parentStroke?.strokeCap ?? StrokeCap.butt
        : StrokeCap.values.firstWhere(
            (StrokeCap sc) => sc.toString() == 'StrokeCap.$rawStrokeCap',
            orElse: () => StrokeCap.butt,
          ),
    strokeJoin: rawLineJoin == ''
        ? parentStroke?.strokeJoin ?? StrokeJoin.miter
        : StrokeJoin.values.firstWhere(
            (StrokeJoin sj) => sj.toString() == 'StrokeJoin.$rawLineJoin',
            orElse: () => StrokeJoin.miter,
          ),
    strokeMiterLimit: rawMiterLimit == ''
        ? parentStroke?.strokeMiterLimit ?? 4.0
        : double.parse(rawMiterLimit),
    strokeWidth: rawStrokeWidth == ''
        ? parentStroke?.strokeWidth ?? 1.0
        : double.parse(rawStrokeWidth),
  );
  return paint;
}

DrawablePaint parseFill(
  List<XmlAttribute> el,
  Rect bounds,
  DrawableDefinitionServer definitions,
  DrawablePaint parentFill,
) {
  final String rawFill = getAttribute(el, 'fill');
  final String rawOpacity = getAttribute(el, 'fill-opacity');

  final double opacity = rawOpacity == ''
      ? parentFill?.color?.opacity ?? 1.0
      : double.parse(rawOpacity).clamp(0.0, 1.0);

  if (rawFill.startsWith('url')) {
    return _getDefinitionPaint(
      PaintingStyle.fill,
      rawFill,
      definitions,
      bounds,
      opacity: opacity,
    );
  }
  if (rawFill == '' && parentFill == DrawablePaint.empty) {
    return null;
  }
  if (rawFill == 'none') {
    return DrawablePaint.empty;
  }

  return DrawablePaint(
    PaintingStyle.fill,
    color: rawFill == ''
        ? (parentFill?.color ?? colorBlack).withOpacity(opacity)
        : parseColor(rawFill).withOpacity(opacity),
  );
}

PathFillType parseFillRule(List<XmlAttribute> attributes,
    [String attr = 'fill-rule', String def = 'nonzero']) {
  final String rawFillRule = getAttribute(attributes, attr, def: def);
  return parseRawFillRule(rawFillRule);
}

Path applyTransformIfNeeded(Path path, List<XmlAttribute> attributes) {
  final Matrix4 transform =
      parseTransform(getAttribute(attributes, 'transform', def: null));

  if (transform != null) {
    return path.transform(transform.storage);
  } else {
    return path;
  }
}

List<Path> parseClipPath(
  List<XmlAttribute> attributes,
  DrawableDefinitionServer definitions,
) {
  final String rawClipAttribute = getAttribute(attributes, 'clip-path');
  if (rawClipAttribute != '') {
    return definitions.getClipPath(rawClipAttribute);
  }

  return null;
}

FontWeight parseFontWeight(String fontWeight) {
  if (fontWeight == null) {
    return null;
  }
  switch (fontWeight) {
    case '100':
      return FontWeight.w100;
    case '200':
      return FontWeight.w200;
    case '300':
      return FontWeight.w300;
    case 'normal':
    case '400':
      return FontWeight.w400;
    case '500':
      return FontWeight.w500;
    case '600':
      return FontWeight.w600;
    case 'bold':
    case '700':
      return FontWeight.w700;
    case '800':
      return FontWeight.w800;
    case '900':
      return FontWeight.w900;
  }
  throw UnsupportedError('Attribute value for font-weight="$fontWeight"'
      ' is not supported');
}
