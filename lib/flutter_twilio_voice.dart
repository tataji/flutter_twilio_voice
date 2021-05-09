import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum EventChannelMessageType { log, call_state, token }
enum CallState { ringing, connected, call_ended, unhold, hold, unmute, mute, speaker_on, speaker_off, answer }
enum CallDirection { incoming, outgoing }

class EventChannelMessage
{
  final EventChannelMessageType type;
  final String serializedPayload;

  EventChannelMessage(this.type, this.serializedPayload);
}

class LogEntry
{
  final String severity;
  final String message;
  final String exception;

  LogEntry(this.severity, this.message, [this.exception]);
}

typedef OnDeviceTokenChanged = Function(String token);

class FlutterTwilioVoice {
  static const MethodChannel _channel = const MethodChannel('flutter_twilio_voice/messages');

  static const EventChannel _eventChannel = EventChannel('flutter_twilio_voice/events');

  static Stream<CallState> _callStateMessages;
  static Stream<LogEntry> _logEntryMessages;
  static Stream<String> _deviceTokenMessages;
  static Stream<EventChannelMessage> _eventChannelMessages;
  static String callFrom;
  static String callTo;
  static int callStartedOn;
  static CallDirection callDirection = CallDirection.incoming;
  static OnDeviceTokenChanged deviceTokenChanged;

  static Stream<EventChannelMessage> get eventChannelMessages {
    if (_eventChannelMessages == null) {
      _eventChannelMessages = _eventChannel.receiveBroadcastStream()
                                .map((event) => _parseEventChannelMessage(event));
    }
    return _eventChannelMessages;
  }

  static Stream<CallState> get callStateMessages {
    if (_callStateMessages == null) {
      _callStateMessages = eventChannelMessages
                              .where((event) => event.type != EventChannelMessageType.log)
                              .map((event) => _parseCallStateMessage(event.serializedPayload));
    }
    return _callStateMessages;
  }

  static Stream<String> get deviceTokenMessages {
    if (_deviceTokenMessages == null) {
      _deviceTokenMessages = eventChannelMessages
                              .where((event) => event.type == EventChannelMessageType.token)
                              .map((event) => _parseDeviceTokenMessage(event.serializedPayload));

      // historical behavior - on subscription, we start a listener to fire the old event.
      // Technically, the only event is no longer needed - as we have streams.
      _deviceTokenMessages
        .listen((event) => deviceTokenChanged(event));
    }
    return _deviceTokenMessages;
  }

  static var _logStreamController = StreamController<LogEntry>();

  static Stream<LogEntry> get logEntryMessages {
    if (_logEntryMessages == null) {
      
      eventChannelMessages
        .where((event) => event.type == EventChannelMessageType.log)
        .map((event) => _parseLogEntryMessage(event.serializedPayload))
        .listen((event) => _logStreamController.add(event));
     
      _logEntryMessages = _logStreamController.stream;
    }
    return _logEntryMessages;
  }

  static void setOnDeviceTokenChanged(OnDeviceTokenChanged deviceTokenChanged) {
    FlutterTwilioVoice.deviceTokenChanged = deviceTokenChanged;
  }

  static Future<bool> tokens({@required String accessToken, String deviceToken}) {
    assert(accessToken != null);
    return _channel.invokeMethod('tokens', <String, dynamic>{"accessToken": accessToken, "deviceToken": deviceToken});
  }

  static Future<bool> unregister(String accessToken) {
    return _channel.invokeMethod('unregister', <String, dynamic>{"accessToken": accessToken});
  }

  static Future<bool> makeCall({@required String from, @required String to, Map<String, dynamic> extraOptions}) {
    assert(to != null);
    assert(from != null);
    var options = extraOptions != null ? extraOptions : Map<String, dynamic>();
    options['from'] = from;
    options['to'] = to;
    callFrom = from;
    callTo = to;
    callDirection = CallDirection.outgoing;
    return _channel.invokeMethod('makeCall', options);
  }

  static Future<bool> hangUp() {
    return _channel.invokeMethod('hangUp', <String, dynamic>{});
  }

  static Future<bool> answer() {
    return _channel.invokeMethod('answer', <String, dynamic>{});
  }

  static Future<bool> holdCall() {
    return _channel.invokeMethod('holdCall', <String, dynamic>{});
  }

  static Future<bool> muteCall() {
    return _channel.invokeMethod('muteCall', <String, dynamic>{});
  }

  static Future<bool> toggleSpeaker(bool speakerIsOn) {
    assert(speakerIsOn != null);
    return _channel.invokeMethod('toggleSpeaker', <String, dynamic>{"speakerIsOn": speakerIsOn});
  }

  static Future<bool> sendDigits(String digits) {
    assert(digits != null);
    return _channel.invokeMethod('sendDigits', <String, dynamic>{"digits": digits});
  }

  static Future<bool> requestBackgroundPermissions() {
    return _channel.invokeMethod('requestBackgroundPermissions', {});
  }

  static Future<bool> requiresBackgroundPermissions() {
    return _channel.invokeMethod('requiresBackgroundPermissions', {});
  }

  static Future<bool> isOnCall() {
    return _channel.invokeMethod('isOnCall', <String, dynamic>{});
  }

  static Future<bool> registerClient(String clientId, String clientName) {
    return _channel.invokeMethod('registerClient', <String, dynamic>{"id": clientId, "name": clientName});
  }

  static Future<bool> unregisterClient(String clientId) {
    return _channel.invokeMethod('unregisterClient', <String, dynamic>{"id": clientId});
  }

  static Future<bool> setDefaultCallerName(String callerName) {
    return _channel.invokeMethod('defaultCaller', <String, dynamic>{"defaultCaller": callerName});
  }

  /// Twilio can pass custom parameters (key-value pairs) with the CallInvite.
  /// Here we can pass a Caller Id (a friendly name) from the TWIML application server.
  /// Use this to set the key name, used to lookup the caller id in the custom parameters dictionary.
  static Future<bool> setCallerIdCustomParameterKey(String key) {
    return _channel.invokeMethod('callerIdCustomParameterKey', <String, dynamic>{"key": key});
  }

  static Future<bool> hasMicAccess() {
    return _channel.invokeMethod('hasMicPermission', {});
  }

  static Future<bool> requestMicAccess() {
    return _channel.invokeMethod('requestMicPermission', {});
  }

  static Future showBackgroundCallUI() {
    return _channel.invokeMethod("backgroundCallUI", {});
  }

  static String getFrom() {
    return callFrom;
  }

  static String getTo() {
    return callTo;
  }

  static int getCallStartedOn() {
    return callStartedOn;
  }

  static CallDirection getCallDirection() {
    return callDirection;
  }

  static CallDirection getCallDirection() {
    return callDirection;
  }

  static List<String> splitAtFirstPipe(String sz)
    => sz.split(RegExp(r"(?<!.*\|.*)\|")).toList();

  static LogEntry _parseLogEntryMessage(String serializedMessage) 
  {
    // _logStreamController.add(LogEntry('WARN', 'custom log message'));
    var levelAndMessage = splitAtFirstPipe(serializedMessage);
    var level = '';
    var message = '';
    if (levelAndMessage.length == 1)
    {
      message = levelAndMessage[0];
    } else if (levelAndMessage.length == 2)
    {
      level = levelAndMessage[0];
      message = levelAndMessage[1];
    }
    return LogEntry(level, message);
  }

  static EventChannelMessage _parseEventChannelMessage(String serializedMessage) {
    var typeAndPayload = splitAtFirstPipe(serializedMessage);
    switch(typeAndPayload[0])
    {
      case "DEVICETOKEN":
        return EventChannelMessage(EventChannelMessageType.token, typeAndPayload[1]);
      case "LOG":
        return EventChannelMessage(EventChannelMessageType.log, typeAndPayload[1]);
      case "Connected":
      case "Ringing":
      case "Answer":
      case "Call Ended":
      case "Hold":
      case "Unhold":
      case "Mute":
      case "Unmute":
      case "Speaker On":
      case "Speaker Off":
        return EventChannelMessage(EventChannelMessageType.call_state, serializedMessage);
      default:
        return EventChannelMessage(EventChannelMessageType.log, 'WARN|Unknown event type ${typeAndPayload[0]}');
    }
  }

  static String _parseDeviceTokenMessage(String serializedPayload) {
      return serializedPayload;
  }

  static CallState _parseCallStateMessage(String serializedPayload) {
    CallState result;
    var stateAndPayload = splitAtFirstPipe(serializedPayload);
    try{
      var state = stateAndPayload[0];
      var payload = stateAndPayload.length == 2 ? stateAndPayload[1].split('|') : [];
      switch (state)
      {
        case 'Connected':
          callFrom = _prettyPrintNumber(payload[0]);
          callTo = _prettyPrintNumber(payload[1]);
          callDirection = ("Incoming" == payload[2] ? CallDirection.incoming : CallDirection.outgoing);
          if (callStartedOn == null) {
            callStartedOn = DateTime.now().millisecondsSinceEpoch;
          }
          print('Connected - From: $callFrom, To: $callTo, StartOn: $callStartedOn, Direction: $callDirection');
          result = CallState.connected;
        break;
        case 'Ringing':
          callFrom = _prettyPrintNumber(payload[0]);
          callTo = _prettyPrintNumber(payload[1]);

          print('Ringing - From: $callFrom, To: $callTo, Direction: $callDirection');
          result = CallState.ringing;      
        break;
        case 'Answer':
          callFrom = _prettyPrintNumber(payload[0]);
          callTo = _prettyPrintNumber(payload[1]);
          callDirection = CallDirection.incoming;
          print('Answer - From: $callFrom, To: $callTo, Direction: $callDirection');
          result = CallState.answer;
        break;
        case 'Call Ended':
          callStartedOn = null;
          callFrom = null;
          callTo = null;
          callDirection = CallDirection.incoming;
          result = CallState.call_ended;
        break;      
        case 'Unhold':
          result = CallState.unhold;
          break;
        case 'Hold':
          result = CallState.hold;
          break;
        case 'Unmute':
          result = CallState.unmute;
          break;
        case 'Mute':
          result = CallState.mute;
          break;
        case 'Speaker On':
          result = CallState.speaker_on;
          break;
        case 'Speaker Off':
          result = CallState.speaker_off;
          break;
        default:
          print('$state is not a valid CallState.');
          throw ArgumentError('$state is not a valid CallState.');
      }
    } catch(e) {
      _logStreamController.add(LogEntry('ERROR', 'Unable to parse CallState message "$serializedPayload"'));
    }
    return result;
  }

  static String _prettyPrintNumber(String phoneNumber) {
    if (null == phoneNumber || phoneNumber == '')
      return '';

    if (phoneNumber.indexOf('client:') > -1) {
      return phoneNumber.split(':')[1];
    }
    if (phoneNumber.substring(0, 1) == '+') {
      phoneNumber = phoneNumber.substring(1);
    }
    if (phoneNumber.length == 7) {
      return phoneNumber.substring(0, 3) + "-" + phoneNumber.substring(3);
    }
    if (phoneNumber.length < 10) {
      return phoneNumber;
    }
    int start = 0;
    if (phoneNumber.length == 11) {
      start = 1;
    }
    return "(" +
        phoneNumber.substring(start, start + 3) +
        ") " +
        phoneNumber.substring(start + 3, start + 6) +
        "-" +
        phoneNumber.substring(start + 6);
  }
}
