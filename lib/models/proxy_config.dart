import 'dart:io';

/// Proxy configuration for the network tools (`http_fetch` / `web_search`).
///
/// Mirrors the `http_proxy` / `https_proxy` / `no_proxy` environment variables.
class ProxyConfig {
  ProxyConfig({
    this.httpProxy = '',
    this.httpsProxy = '',
    this.noProxy = '',
    this.applyToHttpFetch = true,
  });

  /// e.g. `http://127.0.0.1:7890`.
  String httpProxy;
  String httpsProxy;

  /// Comma separated bypass list: hosts, domain suffixes, IPs and IPv4 CIDRs
  /// (e.g. `localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12`).
  String noProxy;

  /// Whether the proxy is applied to the `http_fetch` tool.
  bool applyToHttpFetch;

  bool get isEmpty => httpProxy.trim().isEmpty && httpsProxy.trim().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        if (httpProxy.isNotEmpty) 'http_proxy': httpProxy,
        if (httpsProxy.isNotEmpty) 'https_proxy': httpsProxy,
        if (noProxy.isNotEmpty) 'no_proxy': noProxy,
        'apply_to_http_fetch': applyToHttpFetch,
      };

  factory ProxyConfig.fromJson(Object? value) {
    if (value is String) return ProxyConfig(httpProxy: value, httpsProxy: value);
    final json = value is Map ? value : const <String, Object?>{};
    return ProxyConfig(
      httpProxy: '${json['http_proxy'] ?? ''}',
      httpsProxy: '${json['https_proxy'] ?? ''}',
      noProxy: '${json['no_proxy'] ?? ''}',
      applyToHttpFetch:
          json.containsKey('apply_to_http_fetch') ? json['apply_to_http_fetch'] == true : true,
    );
  }

  /// The proxy URL to use for [uri], or `null` to connect directly.
  String? proxyFor(Uri uri) {
    if (bypass(uri.host)) return null;
    final proxy = uri.scheme == 'https' ? httpsProxy : httpProxy;
    final chosen = proxy.trim().isNotEmpty
        ? proxy.trim()
        : (httpProxy.trim().isNotEmpty ? httpProxy.trim() : httpsProxy.trim());
    return chosen.isEmpty ? null : chosen;
  }

  /// Whether [host] is covered by the [noProxy] list.
  bool bypass(String host) {
    if (host.isEmpty) return false;
    final bare = host.toLowerCase();
    for (final raw in noProxy.split(',')) {
      final entry = raw.trim().toLowerCase();
      if (entry.isEmpty) continue;
      if (entry == '*') return true;
      if (entry.contains('/')) {
        if (_inCidr(bare, entry)) return true;
        continue;
      }
      final domain = entry.startsWith('.') ? entry.substring(1) : entry;
      if (bare == domain || bare.endsWith('.$domain')) return true;
    }
    return false;
  }

  static bool _inCidr(String host, String cidr) {
    final parts = cidr.split('/');
    if (parts.length != 2) return false;
    final network = _ipv4ToInt(parts[0]);
    final ip = _ipv4ToInt(host);
    final bits = int.tryParse(parts[1]);
    if (network == null || ip == null || bits == null || bits < 0 || bits > 32) {
      return false;
    }
    if (bits == 0) return true;
    final mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
    return (network & mask) == (ip & mask);
  }

  static int? _ipv4ToInt(String value) {
    final octets = value.split('.');
    if (octets.length != 4) return null;
    var result = 0;
    for (final octet in octets) {
      final n = int.tryParse(octet);
      if (n == null || n < 0 || n > 255) return null;
      result = (result << 8) | n;
    }
    return result;
  }
}

/// Normalises `http://host:port` / `host:port` / `host` to `host:port`.
String proxyHostPort(String proxy) {
  var value = proxy.trim();
  final scheme = value.indexOf('://');
  if (scheme >= 0) value = value.substring(scheme + 3);
  final slash = value.indexOf('/');
  if (slash >= 0) value = value.substring(0, slash);
  if (!value.contains(':') && value.isNotEmpty) value = '$value:80';
  return value;
}

/// Builds an [HttpClient] obeying [config] (or one that connects directly).
HttpClient buildProxiedHttpClient(ProxyConfig config) {
  final client = HttpClient();
  if (config.isEmpty) return client;
  client.findProxy = (uri) {
    final proxy = config.proxyFor(uri);
    return proxy == null ? 'DIRECT' : 'PROXY ${proxyHostPort(proxy)}';
  };
  return client;
}
