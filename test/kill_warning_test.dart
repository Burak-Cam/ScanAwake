import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/alarm_service.dart';

// Review 2026-10-10 #1: the plugin's setWarningNotificationOnKill stops a
// running NotificationOnKillService and then fails to restart it in the same
// main-thread step (isRunning stays true until onDestroy). refreshKillWarning
// sequences a second call after the stop has really completed.
void main() {
  late List<String> log;
  late int applies;
  late int sleeps;

  Future<void> run(List<bool> reads, {int maxPolls = 20}) {
    var i = 0;
    return refreshKillWarning(
      isRunning: () async {
        final v = reads[i < reads.length ? i : reads.length - 1];
        i++;
        log.add('read:$v');
        return v;
      },
      apply: () async {
        applies++;
        log.add('apply');
      },
      sleep: (_) async {
        sleeps++;
        log.add('sleep');
      },
      maxPolls: maxPolls,
    );
  }

  setUp(() {
    log = [];
    applies = 0;
    sleeps = 0;
  });

  test('service not running -> a single apply starts it with the new text',
      () async {
    await run([false]);
    expect(applies, 1);
    expect(sleeps, 0);
  });

  test('service running -> second apply only after it really stopped',
      () async {
    await run([true, true, true, false]);
    expect(applies, 2);
    expect(sleeps, 3);
    expect(log, [
      'read:true',
      'apply',
      'sleep',
      'read:true',
      'sleep',
      'read:true',
      'sleep',
      'read:false',
      'apply',
    ]);
  });

  test('stop never completes -> no second apply (would stop a live service)',
      () async {
    await run([true], maxPolls: 5);
    expect(applies, 1);
    expect(sleeps, 5);
  });
}
