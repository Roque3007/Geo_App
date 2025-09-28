/*
ChatGPT NLP wrapper

This service provides a small wrapper to call the OpenAI Chat Completions API
and parse the response into structured Task fields (title, locationText,
optional lat/lng). It is intentionally minimal and defensive: you must provide
an API key at runtime (do not commit the key into source control).

Setup:
  1) Add your OpenAI API key to a secure storage or environment variable. For
     testing, you can place it in a `.env` file and read it using flutter_dotenv
     (recommended). Do NOT commit secrets.
  2) This wrapper uses the REST API via `http` package (already added to
     pubspec.yaml). If you prefer an official SDK, adapt accordingly.

Usage:
  final nlp = ChatGptNlp(apiKey: 'sk-...');
  final task = await nlp.parseToTask('remind me to pick up package at home tomorrow', provider);

This file does not perform retries or exponential backoff — add those for
production.
*/

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';

class ChatGptNlp {
  final String apiKey;
  final _uuid = const Uuid();
  final String _baseUrl = 'https://api.openai.com/v1/chat/completions';

  ChatGptNlp({required this.apiKey});

  // Prompt template: instruct the model to return JSON strictly with the
  // following fields: title (string), locationText (string), lat (number|null), lng (number|null).
  String _buildPrompt(String userText) {
    return '''You are a helpful assistant that extracts structured task data from a user's short natural language instruction.
Return a JSON object only (no explanatory text) with these keys:
- title: short title for the task
- locationText: short location or metadata (can include tracking/carrier info)
- lat: decimal latitude or null if not known
- lng: decimal longitude or null if not known

User input: "$userText"
''';
  }

  Future<Map<String, dynamic>> _callChatCompletion(String prompt) async {
    final body = {
      'model': 'gpt-4o-mini',
      'messages': [
        {'role': 'system', 'content': 'You are a JSON-only extractor.'},
        {'role': 'user', 'content': prompt}
      ],
      'temperature': 0.0,
      'max_tokens': 300,
    };

    final resp = await http.post(Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(body));

    if (resp.statusCode != 200) {
      throw Exception('OpenAI API error: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    // Extract assistant message content
    final choices = decoded['choices'] as List<dynamic>;
    if (choices.isEmpty) throw Exception('No choices returned from OpenAI');
    final message = choices[0]['message'] as Map<String, dynamic>;
    final content = message['content'] as String;
    // Sometimes the model may include markdown - strip code fences if present
    final cleaned = _stripCodeFences(content).trim();
    final parsed = jsonDecode(cleaned) as Map<String, dynamic>;
    return parsed;
  }

  String _stripCodeFences(String s) {
    // remove ```json ... ``` or ``` ... ```
    final fenceRegex = RegExp(r"```(?:json)?\\n([\s\S]*?)```",
        multiLine: true, caseSensitive: false);
    final m = fenceRegex.firstMatch(s);
    if (m != null) return m.group(1)!;
    return s;
  }

  // Public method: parse natural language into a Task and add to provider.
  // lat/lng are nullable in the returned JSON; if absent or null we set 0.0
  // as placeholders.
  Future<Task> parseToTask(String userText, TaskProvider provider) async {
    final prompt = _buildPrompt(userText);
    final Map<String, dynamic> jsonResp = await _callChatCompletion(prompt);

    final title = (jsonResp['title'] ?? '').toString();
    final locationText = (jsonResp['locationText'] ?? '').toString();
    double lat = 0.0, lng = 0.0;
    if (jsonResp.containsKey('lat') && jsonResp['lat'] != null) {
      lat = (jsonResp['lat'] is num) ? (jsonResp['lat'] as num).toDouble() : double.tryParse(jsonResp['lat'].toString()) ?? 0.0;
    }
    if (jsonResp.containsKey('lng') && jsonResp['lng'] != null) {
      lng = (jsonResp['lng'] is num) ? (jsonResp['lng'] as num).toDouble() : double.tryParse(jsonResp['lng'].toString()) ?? 0.0;
    }

    final task = Task(
      id: _uuid.v4(),
      title: title.isNotEmpty ? title : (userText.length > 48 ? '${userText.substring(0, 45)}...' : userText),
      locationText: locationText,
      lat: lat,
      lng: lng,
    );

    provider.addTask(task);
    return task;
  }
}
