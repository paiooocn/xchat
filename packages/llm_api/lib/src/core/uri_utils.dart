/// URI helpers.
library;

/// Joins [base] with [path] without the `Uri.resolve` pitfall.
///
/// `Uri.parse('https://host/v1').resolve('/chat/completions')` throws away the
/// `/v1` prefix, which is almost never what an API base URL means.
Uri joinUri(Uri base, String path, {Map<String, String>? query}) {
  var basePath = base.path;
  while (basePath.endsWith('/') && basePath.isNotEmpty) {
    basePath = basePath.substring(0, basePath.length - 1);
  }
  final suffix = path.isEmpty
      ? ''
      : path.startsWith('/')
          ? path
          : '/$path';
  final merged = <String, String>{...base.queryParameters, ...?query};
  return base.replace(
    path: '$basePath$suffix',
    queryParameters: merged.isEmpty ? null : merged,
  );
}
