/// Multimodal message parts.
library;

import 'json_utils.dart';

/// A piece of a user message: plain text, an image, …
sealed class ContentPart {
  const ContentPart();

  /// Short text part.
  const factory ContentPart.text(String text) = TextPart;

  /// Image referenced by a public URL.
  factory ContentPart.imageUrl(String url, {String? mimeType}) =>
      ImagePart(url: url, mimeType: mimeType ?? 'image/png');

  /// Image passed inline as base64 (no data-URI prefix expected).
  factory ContentPart.imageBase64(String data, {String mimeType = 'image/png'}) =>
      ImagePart(base64Data: data, mimeType: mimeType);

  Map<String, Object?> toJson();
}

/// Plain text.
final class TextPart extends ContentPart {
  const TextPart(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'text': text};
}

/// An image, either remote ([url]) or inline ([base64Data]).
final class ImagePart extends ContentPart {
  const ImagePart({this.url, this.base64Data, this.mimeType = 'image/png'})
      : assert(url != null || base64Data != null, 'image needs a url or base64 data');

  final String? url;
  final String? base64Data;
  final String mimeType;

  /// `data:` URI form, used by the OpenAI-compatible wire format.
  String toDataUri() {
    if (url != null) return url!;
    return 'data:$mimeType;base64,$base64Data';
  }

  @override
  Map<String, Object?> toJson() => pruneNulls({
        'type': 'image',
        'url': url,
        'base64': base64Data,
        'mime_type': mimeType,
      });

  static ImagePart fromJson(Map<String, Object?> json) => ImagePart(
        url: asString(json['url']),
        base64Data: asString(json['base64']),
        mimeType: asString(json['mime_type']) ?? 'image/png',
      );
}

/// Parses a part list produced by [ContentPart.toJson].
List<ContentPart> partsFromJson(Object? value) {
  final out = <ContentPart>[];
  for (final raw in asList(value)) {
    final map = asMap(raw);
    if (map['type'] == 'image') {
      out.add(ImagePart.fromJson(map));
    } else {
      out.add(TextPart(asString(map['text']) ?? ''));
    }
  }
  return out;
}
