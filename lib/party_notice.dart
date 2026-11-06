// Watch together notices ("Maya paused", "Jo joined", "The room has closed"): what kind each
// one is and who it's about, so every player can draw it the same way (the person's initial in
// their colour with a small badge for what they did, or an icon for problems).
//
// The room code (syncplay.dart) only says the sentence; this reads it. Pure Dart, checked by
// test/party_notice_test.dart.

import 'dart:convert' show utf8;

enum NoticeKind { pause, play, seek, join, leave, waiting, warn, closed, info }

class PartyNotice {
  const PartyNotice(this.text, this.kind, [this.who]);
  final String text;
  final NoticeKind kind;
  final String? who; // the person it's about, when there is one

  bool get aboutPerson => who != null && who!.isNotEmpty;
}

PartyNotice describeNotice(String text) {
  final t = text.trim();
  String before(String marker) => t.substring(0, t.indexOf(marker)).trim();

  if (t == 'The room has closed' || t == 'The room stopped playing') return PartyNotice(t, NoticeKind.closed);
  if (t.startsWith('Waiting for ')) {
    final who = t.substring(12).replaceAll('…', '').trim();
    // "Waiting for everyone", "Waiting for the next episode": not a person.
    final person = who != 'everyone' && !who.startsWith('the ');
    return PartyNotice(t, NoticeKind.waiting, person ? who : null);
  }
  if (t.startsWith('Having trouble lining up')) return PartyNotice(t, NoticeKind.warn);
  if (t.contains("'s connection is slow")) return PartyNotice(t, NoticeKind.warn, before("'s connection"));
  if (t.contains("can't open")) return PartyNotice(t, NoticeKind.warn);
  if (t.endsWith(' pressed play')) return PartyNotice(t, NoticeKind.play, before(' pressed play'));
  if (t.endsWith(' paused')) return PartyNotice(t, NoticeKind.pause, before(' paused'));
  if (t.contains(' jumped to ')) return PartyNotice(t, NoticeKind.seek, before(' jumped to '));
  if (t.endsWith(' joined')) return PartyNotice(t, NoticeKind.join, before(' joined'));
  if (t.endsWith(' left')) return PartyNotice(t, NoticeKind.leave, before(' left'));
  return PartyNotice(t, NoticeKind.info);
}

/// Each person's colour, the same on every device (picked by the name's length in bytes).
const partyColors = [0xFF6F8CFA, 0xFFEE6E90, 0xFF4FD1AE, 0xFFF2B05A, 0xFFA884F5, 0xFF5FC2EE];
int partyColorOf(String name) => partyColors[utf8.encode(name).length % partyColors.length];
