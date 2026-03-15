import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:inthepark/models/feed_article.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

class NewsFeedService {
  static const Duration _cacheTtl = Duration(hours: 1);
  static const Duration _redditMaxAge = Duration(days: 2);
  static const String _cacheArticlesKey = 'newsFeed.articles.v4';
  static const String _cacheTimestampKey = 'newsFeed.timestamp.v4';
  static const int _requestTimeoutSeconds = 12;

  Future<List<FeedArticle>> getArticles({
    bool forceRefresh = false,
    int limit = 30,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = _readCachedArticles(prefs);
    final cachedAtMs = prefs.getInt(_cacheTimestampKey);
    final cachedAt = cachedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(cachedAtMs);

    final cacheIsFresh = cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl &&
        cached.isNotEmpty;

    if (!forceRefresh && cacheIsFresh) {
      return _filterEligibleArticles(cached)
          .take(limit)
          .toList(growable: false);
    }

    try {
      final fetched = await _fetchLatestArticles(limit: limit);
      if (fetched.isNotEmpty) {
        await prefs.setString(
          _cacheArticlesKey,
          jsonEncode(fetched.map((e) => e.toJson()).toList()),
        );
        await prefs.setInt(
          _cacheTimestampKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return fetched;
      }
    } catch (_) {
      // Fall back to cache below.
    }

    return _filterEligibleArticles(cached).take(limit).toList(growable: false);
  }

  Future<List<FeedArticle>> _fetchLatestArticles({required int limit}) async {
    final results = await Future.wait<List<FeedArticle>>([
      _fetchSourceFeeds(
        source: 'AKC',
        urls: const [
          'https://www.akc.org/expert-advice/feed/?category=health',
          'https://www.akc.org/expert-advice/feed/?category=training',
          'https://www.akc.org/expert-advice/feed/?category=lifestyle',
        ],
      ),
      _fetchSourceFeeds(
        source: 'PetMD',
        urls: const [
          'https://www.petmd.com/rss/dog.health',
          'https://www.petmd.com/rss/dog.wellness',
          'https://www.petmd.com/rss/news.rss',
        ],
      ),
      _fetchSourceFeeds(
        source: 'Dogster',
        urls: const [
          'https://www.dogster.com/feed',
        ],
      ),
      _fetchRedditFeed(),
    ]);

    final perSourceArticles = <List<FeedArticle>>[];
    for (final sourceArticles in results) {
      final byKey = <String, FeedArticle>{};
      for (final article in _filterEligibleArticles(sourceArticles)) {
        final key = _dedupeKey(article);
        final existing = byKey[key];
        if (existing == null ||
            _publishedMillis(article) > _publishedMillis(existing)) {
          byKey[key] = article;
        }
      }
      final deduped = byKey.values.toList()
        ..sort((a, b) => _publishedMillis(b).compareTo(_publishedMillis(a)));
      perSourceArticles.add(deduped);
    }

    final seen = <String>{};
    final mixed = <FeedArticle>[];
    var addedInPass = true;

    while (mixed.length < limit && addedInPass) {
      addedInPass = false;
      for (final sourceArticles in perSourceArticles) {
        while (sourceArticles.isNotEmpty) {
          final candidate = sourceArticles.removeAt(0);
          if (seen.add(_dedupeKey(candidate))) {
            mixed.add(candidate);
            addedInPass = true;
            break;
          }
        }
        if (mixed.length >= limit) break;
      }
    }

    return mixed.take(limit).toList(growable: false);
  }

  List<FeedArticle> _readCachedArticles(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheArticlesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = (jsonDecode(raw) as List)
          .map((item) =>
              FeedArticle.fromJson(Map<String, dynamic>.from(item as Map)))
          .where(
              (article) => article.title.isNotEmpty && article.url.isNotEmpty)
          .toList(growable: false);
      return _filterEligibleArticles(decoded);
    } catch (_) {
      return const [];
    }
  }

  List<FeedArticle> _filterEligibleArticles(List<FeedArticle> articles) {
    return articles
        .where((article) =>
            article.title.isNotEmpty &&
            article.url.isNotEmpty &&
            _isArticleFreshEnough(article))
        .toList(growable: false);
  }

  bool _isArticleFreshEnough(FeedArticle article) {
    if (article.source.trim().toLowerCase() != 'reddit') {
      return true;
    }
    final publishedAt = article.publishedAt;
    if (publishedAt == null) return false;
    final cutoff = DateTime.now().subtract(_redditMaxAge);
    return !publishedAt.isBefore(cutoff);
  }

  Future<List<FeedArticle>> _fetchSourceFeeds({
    required String source,
    required List<String> urls,
  }) async {
    final articles = <FeedArticle>[];
    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: const {
            'User-Agent': 'InThePark/1.0 (+https://inthepark.app)',
            'Accept':
                'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
          },
        ).timeout(const Duration(seconds: _requestTimeoutSeconds));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }

        final body = utf8.decode(response.bodyBytes);
        final parsed = _parseXmlFeed(body, source: source);
        articles.addAll(parsed);
      } catch (_) {
        // Ignore one feed URL and continue.
      }
    }

    return articles;
  }

  Future<List<FeedArticle>> _fetchRedditFeed() async {
    const urls = [
      'https://www.reddit.com/r/dogs/.rss',
      'https://www.reddit.com/r/puppy101/.rss',
    ];

    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: const {
            'User-Agent': 'InThePark/1.0 (+https://inthepark.app)',
            'Accept': 'application/atom+xml, application/xml, text/xml',
          },
        ).timeout(const Duration(seconds: _requestTimeoutSeconds));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }

        final body = utf8.decode(response.bodyBytes);
        final parsed = _parseXmlFeed(body, source: 'Reddit');
        if (parsed.isNotEmpty) {
          return parsed;
        }
      } catch (_) {
        // Try next candidate URL.
      }
    }

    try {
      return await _fetchRedditJsonFeed();
    } catch (_) {
      return const [];
    }
  }

  Future<List<FeedArticle>> _fetchRedditJsonFeed() async {
    final response = await http.get(
      Uri.parse('https://www.reddit.com/r/dogs/hot.json?limit=12'),
      headers: const {
        'User-Agent': 'InThePark/1.0 (+https://inthepark.app)',
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: _requestTimeoutSeconds));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }

    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items =
        ((((decoded['data'] ?? const {}) as Map)['children']) as List? ??
                const [])
            .cast<Map>();

    return items
        .map((item) => Map<String, dynamic>.from(item['data'] as Map))
        .where((data) =>
            (data['title'] ?? '').toString().isNotEmpty &&
            (data['url'] ?? '').toString().startsWith('http'))
        .map(
          (data) => FeedArticle(
            id: _buildId(
              'Reddit',
              (data['permalink'] ?? data['url'] ?? '').toString(),
              (data['title'] ?? '').toString(),
            ),
            title: _cleanText((data['title'] ?? '').toString()),
            summary: _buildSummary(
              (data['selftext'] ?? '').toString(),
              (data['selftext'] ?? '').toString(),
            ),
            url: (data['url'] ?? '').toString(),
            imageUrl: _redditPreviewImage(data),
            source: 'Reddit',
            publishedAt: _redditPublishedAt(data['created_utc']),
          ),
        )
        .toList(growable: false);
  }

  DateTime? _redditPublishedAt(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (raw * 1000).round(),
        isUtc: true,
      ).toLocal();
    }
    return null;
  }

  String _redditPreviewImage(Map<String, dynamic> data) {
    final preview = data['preview'];
    if (preview is Map) {
      final images = preview['images'];
      if (images is List && images.isNotEmpty && images.first is Map) {
        final source = (images.first as Map)['source'];
        if (source is Map) {
          final url = (source['url'] ?? '').toString();
          if (url.startsWith('http')) {
            return url.replaceAll('&amp;', '&');
          }
        }
      }
    }
    final thumbnail = (data['thumbnail'] ?? '').toString();
    if (thumbnail.startsWith('http')) return thumbnail;
    return '';
  }

  List<FeedArticle> _parseXmlFeed(String xmlString, {required String source}) {
    final document = XmlDocument.parse(xmlString);
    final articles = <FeedArticle>[];

    final itemNodes = document.findAllElements('item');
    if (itemNodes.isNotEmpty) {
      for (final item in itemNodes) {
        final title = _childText(item, 'title');
        final link = _childText(item, 'link');
        if (title.isEmpty || link.isEmpty) continue;

        final description = _childMarkup(item, 'description');
        final content = _childMarkup(item, 'encoded');
        final publishedAt = _parsePublishedAt(
          _childText(item, 'pubDate'),
        );
        final imageUrl = _extractImageUrl(item, description, content);

        articles.add(
          FeedArticle(
            id: _buildId(source, link, title),
            title: _cleanText(title),
            summary: _buildSummary(description, content),
            url: link.trim(),
            imageUrl: imageUrl,
            source: source,
            publishedAt: publishedAt,
          ),
        );
      }
      return articles;
    }

    final entryNodes = document.findAllElements('entry');
    for (final entry in entryNodes) {
      final title = _childText(entry, 'title');
      final link = _extractAtomLink(entry);
      if (title.isEmpty || link.isEmpty) continue;

      final summary = _childMarkup(entry, 'summary');
      final content = _childMarkup(entry, 'content');
      final publishedAt = _parsePublishedAt(
        _childText(entry, 'published').isNotEmpty
            ? _childText(entry, 'published')
            : _childText(entry, 'updated'),
      );
      final imageUrl = _extractImageUrl(entry, summary, content);

      articles.add(
        FeedArticle(
          id: _buildId(source, link, title),
          title: _cleanText(title),
          summary: _buildSummary(summary, content),
          url: link.trim(),
          imageUrl: imageUrl,
          source: source,
          publishedAt: publishedAt,
        ),
      );
    }

    return articles;
  }

  String _childText(XmlElement parent, String localName) {
    for (final element in parent.childElements) {
      if (element.name.local == localName) {
        return element.innerText.trim();
      }
    }
    return '';
  }

  String _childMarkup(XmlElement parent, String localName) {
    for (final element in parent.childElements) {
      if (element.name.local == localName) {
        final xml = element.innerXml.trim();
        if (xml.isNotEmpty) return xml;
        return element.innerText.trim();
      }
    }
    return '';
  }

  String _extractAtomLink(XmlElement entry) {
    for (final element in entry.childElements) {
      if (element.name.local != 'link') continue;
      final rel = element.getAttribute('rel');
      final href = element.getAttribute('href') ?? '';
      if (href.isEmpty) continue;
      if (rel == null || rel == 'alternate') return href;
    }
    return '';
  }

  DateTime? _parsePublishedAt(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final iso = DateTime.tryParse(value);
    if (iso != null) return iso.toLocal();

    const patterns = [
      'EEE, dd MMM yyyy HH:mm:ss Z',
      'EEE, dd MMM yyyy HH:mm Z',
      'dd MMM yyyy HH:mm:ss Z',
    ];

    for (final pattern in patterns) {
      try {
        return DateFormat(pattern, 'en_US').parseUtc(value).toLocal();
      } catch (_) {
        // Try next pattern.
      }
    }
    return null;
  }

  String _extractImageUrl(
    XmlElement node,
    String primaryText,
    String fallbackText,
  ) {
    for (final element in node.descendants.whereType<XmlElement>()) {
      final local = element.name.local;
      if (local != 'content' && local != 'thumbnail' && local != 'enclosure') {
        continue;
      }
      final url = element.getAttribute('url') ?? '';
      if (url.startsWith('http')) return url;
    }

    final html = primaryText.isNotEmpty ? primaryText : fallbackText;
    final patterns = [
      RegExp("<img[^>]+src=[\"']([^\"']+)[\"']", caseSensitive: false),
      RegExp("<img[^>]+data-src=[\"']([^\"']+)[\"']", caseSensitive: false),
      RegExp(
        "content=[\"']([^\"']+\\.(?:jpg|jpeg|png|webp))[^\"']*[\"']",
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      final url = match?.group(1) ?? '';
      if (url.startsWith('http')) {
        return url.replaceAll('&amp;', '&');
      }
    }
    return '';
  }

  String _buildSummary(String primary, String fallback) {
    final raw = primary.isNotEmpty ? primary : fallback;
    final cleaned = _cleanText(raw);
    if (cleaned.length <= 180) return cleaned;
    return '${cleaned.substring(0, 177).trimRight()}...';
  }

  String _cleanText(String raw) {
    var text = raw
        .replaceAll('<![CDATA[', ' ')
        .replaceAll(']]>', ' ')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
        .trim();

    text = _decodeHtmlEntities(text);
    text = _decodeHtmlEntities(text);

    text = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(
          RegExp(
            "\\b(?:class|href|rel|target|style|src|alt)=[\"'][^\"']*[\"']",
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
            RegExp(r'\b(?:class|href|rel|target|style|src|alt)=\S+',
                caseSensitive: false),
            ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    text = _decodeHtmlEntities(text).replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.startsWith('<') || text.contains(' class=')) {
      text = text
          .replaceAll(RegExp(r'[<>]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    return text;
  }

  String _decodeHtmlEntities(String input) {
    var text = input;
    const entities = {
      '&amp;': '&',
      '&quot;': '"',
      '&#34;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&nbsp;': ' ',
      '&#160;': ' ',
      '&lt;': '<',
      '&gt;': '>',
    };
    entities.forEach((key, value) {
      text = text.replaceAll(key, value);
    });
    return text;
  }

  String _buildId(String source, String url, String title) {
    final safeSource =
        source.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final basis = url.isNotEmpty ? url : title;
    return '$safeSource-${basis.hashCode.abs()}';
  }

  String _dedupeKey(FeedArticle article) {
    final url = article.url.trim().toLowerCase();
    if (url.isNotEmpty) return url;
    return '${article.source}:${article.title.trim().toLowerCase()}';
  }

  int _publishedMillis(FeedArticle article) =>
      article.publishedAt?.millisecondsSinceEpoch ?? 0;
}
