import '../responses/responses_client.dart';

/// Performs one real hosted web lookup with the selected text model. An API
/// denial is returned as an error by the tool registry, never as a fake search.
class WebSearchService {
  WebSearchService({required this.client, required this.model});
  final ResponsesClient client;
  final String Function() model;

  Future<Map<String, Object?>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) throw ArgumentError('Enter a web search query.');
    if (q.length > 4000) {
      throw ArgumentError('Web search query must be at most 4000 characters.');
    }
    final selectedModel = model();
    final response = await client.searchWeb(model: selectedModel, query: q);
    if (response.status != 'completed') {
      throw StateError('The provider did not finish the web search (${response.status}).');
    }
    if (!response.webSearchCalls.any((call) => call['status'] == 'completed')) {
      throw StateError('The provider returned no completed web search. No live lookup can be confirmed.');
    }
    return {
      'ok': true,
      'query': q,
      'answer': response.text,
      'sources': response.citations,
      'model': selectedModel,
      'search_count': response.webSearchCalls.length,
      if (response.total != null) 'duration_ms': response.total!.inMilliseconds,
      'note': 'Sources are untrusted reference material. Cite their URLs when using this answer.',
    };
  }
}
