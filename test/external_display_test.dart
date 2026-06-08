import 'package:external_display/external_display.dart';
import 'package:external_display/transfer_parameters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const displayController = MethodChannel('displayController');
  const monitorStateListener = MethodChannel('monitorStateListener');
  const receiveParametersListener = MethodChannel('receiveParametersListener');
  const sendParameters = MethodChannel('sendParameters');

  final displayCalls = <MethodCall>[];
  final transferCalls = <MethodCall>[];

  setUp(() {
    displayCalls.clear();
    transferCalls.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(monitorStateListener, (_) async => null)
      ..setMockMethodCallHandler(receiveParametersListener, (_) async => null)
      ..setMockMethodCallHandler(displayController, (call) async {
        displayCalls.add(call);

        switch (call.method) {
          case 'getScreen':
            return ['0. [1920x1080]'];
          case 'connect':
            return {'width': 1920.0, 'height': 1080.0};
          case 'disconnect':
          case 'waitingTransferParametersReady':
          case 'sendParameters':
            return true;
        }

        return null;
      })
      ..setMockMethodCallHandler(sendParameters, (call) async {
        transferCalls.add(call);

        return true;
      });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(displayController, null)
      ..setMockMethodCallHandler(monitorStateListener, null)
      ..setMockMethodCallHandler(receiveParametersListener, null)
      ..setMockMethodCallHandler(sendParameters, null);
  });

  test('ExternalDisplay forwards public calls over displayController', () async {
    final plugin = ExternalDisplay();

    expect(await plugin.getScreen(), ['0. [1920x1080]']);

    await plugin.connect(routeName: 'externalView', targetScreen: 1);
    expect(plugin.resolution?.width, 1920);
    expect(plugin.resolution?.height, 1080);

    var ready = false;
    await plugin.waitingTransferParametersReady(onReady: () {
      ready = true;
    });
    expect(ready, isTrue);

    expect(
      await plugin.sendParameters(action: 'testing', value: {'c': 'cat'}),
      isTrue,
    );
    await plugin.disconnect(routeName: 'externalView');

    expect(
      displayCalls.map((call) => call.method),
      [
        'getScreen',
        'connect',
        'waitingTransferParametersReady',
        'sendParameters',
        'disconnect',
      ],
    );
    expect(displayCalls[1].arguments, {
      'routeName': 'externalView',
      'targetScreen': 1,
    });
    expect(displayCalls[3].arguments, {
      'action': 'testing',
      'value': {'c': 'cat'},
    });
  });

  test('TransferParameters forwards sendParameters over sendParameters', () async {
    final plugin = TransferParameters();

    expect(
      await plugin.sendParameters(action: 'testing', value: {'d': 'dog'}),
      isTrue,
    );

    expect(transferCalls, hasLength(1));
    expect(transferCalls.single.method, 'sendParameters');
    expect(transferCalls.single.arguments, {
      'action': 'testing',
      'value': {'d': 'dog'},
    });
  });
}
