class FeedArticle {
  final String id;
  final String title;
  final String summary;
  final String url;
  final String imageUrl;
  final String source;
  final DateTime? publishedAt;

  const FeedArticle({
    required this.id,
    required this.title,
    required this.summary,
    required this.url,
    required this.imageUrl,
    required this.source,
    required this.publishedAt,
  });

  factory FeedArticle.fromJson(Map<String, dynamic> json) {
    return FeedArticle(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      imageUrl: (json['imageUrl'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      publishedAt: json['publishedAt'] == null
          ? null
          : DateTime.tryParse(json['publishedAt'].toString()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'summary': summary,
      'url': url,
      'imageUrl': imageUrl,
      'source': source,
      'publishedAt': publishedAt?.toIso8601String(),
    };
  }
}
