// Watch together notices: each sentence is read as the right kind, about the right person.

import 'package:flutter_test/flutter_test.dart';
import 'package:player_test/party_notice.dart';

void main() {
  void expectNotice(String text, NoticeKind kind, [String? who]) {
    final n = describeNotice(text);
    expect(n.kind, kind, reason: text);
    expect(n.who, who, reason: text);
  }

  test('what people did', () {
    expectNotice('Maya paused', NoticeKind.pause, 'Maya');
    expectNotice('Maya pressed play', NoticeKind.play, 'Maya');
    expectNotice('Sam jumped to 42:10', NoticeKind.seek, 'Sam');
    expectNotice('Jo joined', NoticeKind.join, 'Jo');
    expectNotice('Jo left', NoticeKind.leave, 'Jo');
    expectNotice('Mary Ann paused', NoticeKind.pause, 'Mary Ann');
  });
  test('waiting', () {
    expectNotice('Waiting for Sam', NoticeKind.waiting, 'Sam');
    expectNotice('Waiting for everyone…', NoticeKind.waiting);
    expectNotice('Waiting for the next episode…', NoticeKind.waiting);
  });
  test('problems', () {
    expectNotice("Sam's connection is slow: carrying on without waiting", NoticeKind.warn, 'Sam');
    expectNotice('Having trouble lining up: press play to start anyway', NoticeKind.warn);
    expectNotice("Someone in the room can't open this video", NoticeKind.warn);
    expectNotice('The room has closed', NoticeKind.closed);
    expectNotice('The room stopped playing', NoticeKind.closed);
  });
  test('anything else is general information', () {
    expectNotice('Party started', NoticeKind.info);
  });
  test('a person keeps the same colour, matching the mpv player', () {
    expect(partyColorOf('Maya'), partyColors[4 % 6]);
    expect(partyColorOf('Jo'), partyColors[2]);
    expect(partyColorOf('Maya'), partyColorOf('Maya'));
  });
}
