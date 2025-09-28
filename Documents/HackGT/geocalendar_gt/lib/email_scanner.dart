import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class EmailScanner {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'https://www.googleapis.com/auth/gmail.readonly'],
  );

  Future<GoogleSignInAccount?> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      return account;
    } catch (e) {
      debugPrint('Google sign in failed: $e');
      return null;
    }
  }

  Future<void> scanAndCreateReminders() async {
    final account = _googleSignIn.currentUser ?? await signIn();
    if (account == null) return;

    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null) return;

    // sign into Firebase with the Google credential so Firestore writes are authenticated
    try {
      final credential = GoogleAuthProvider.credential(
        idToken: auth.idToken,
        accessToken: auth.accessToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
    } catch (e) {
      debugPrint('Firebase sign-in with Google failed: $e');
    }

    // fetch recent messages list
    final listResp = await http.get(
      Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=50',
      ),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (listResp.statusCode != 200) {
      debugPrint('Gmail list failed: ${listResp.statusCode} ${listResp.body}');
      return;
    }

    final listData = json.decode(listResp.body) as Map<String, dynamic>;
    final messages =
        (listData['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    for (final msg in messages) {
      final id = msg['id'] as String?;
      if (id == null) continue;

      // avoid duplicate creation: check a Firestore collection 'parsedMessages'
      final existing = await FirebaseFirestore.instance
          .collection('parsedMessages')
          .doc(id)
          .get();
      if (existing.exists) continue;

      final mResp = await http.get(
        Uri.parse(
          'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=full',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (mResp.statusCode != 200) continue;
      final mData = json.decode(mResp.body) as Map<String, dynamic>;

      final payload = mData['payload'] as Map<String, dynamic>?;
      final headers =
          (payload?['headers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      String subject = '';
      String from = '';
      for (final h in headers) {
        final name = (h['name'] as String?)?.toLowerCase();
        if (name == 'subject') subject = h['value'] as String? ?? '';
        if (name == 'from') from = h['value'] as String? ?? '';
      }

      // simplistic heuristic: if subject or snippet contains 'remind' or 'reminder' or 'meeting'
      final snippet = mData['snippet'] as String? ?? '';
      final lower = '$subject\n$snippet'.toLowerCase();
      if (lower.contains('remind') ||
          lower.contains('reminder') ||
          lower.contains('meeting') ||
          lower.contains('appointment')) {
        // create a reminder doc. We won't try to parse a date/time now; we'll store the email reference
        final doc = {
          'title': subject.isNotEmpty ? subject : 'Email reminder from $from',
          'sourceEmailId': id,
          'createdAt': FieldValue.serverTimestamp(),
          // no location parsed yet — we'll leave location null for now
        };
        await FirebaseFirestore.instance.collection('reminders').add(doc);
        // mark message parsed
        await FirebaseFirestore.instance
            .collection('parsedMessages')
            .doc(id)
            .set({'parsedAt': FieldValue.serverTimestamp()});
        debugPrint('Created reminder from email: $id -> ${doc['title']}');
      }
    }
  }
}
