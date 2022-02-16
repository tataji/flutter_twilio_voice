import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit

public class SwiftFlutterTwilioVoicePlugin: NSObject, FlutterPlugin,  FlutterStreamHandler, PKPushRegistryDelegate, NotificationDelegate, CallDelegate, AVAudioPlayerDelegate, CXProviderDelegate {
    

    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?
    
    let kCachedDeviceToken = "CachedDeviceToken"
    let kClientList = "TwilioContactList"
    private var clients: [String:String]!
    
    var accessToken:String?
    var identity = "alice"
    var callerIdCustomParameterKey: String = "CALLER_ID";    
    var callTo: String = "error"
    var defaultCaller = "Unknown Caller"
    var deviceToken: Data? {
        get{UserDefaults.standard.data(forKey: kCachedDeviceToken)}
        set{UserDefaults.standard.setValue(newValue, forKey: kCachedDeviceToken)}
    }
    var callArgs: Dictionary<String, AnyObject> = [String: AnyObject]()
    
    var voipRegistry: PKPushRegistry
    var incomingPushCompletionCallback: (()->Swift.Void?)? = nil
    
    var callInvite:CallInvite?
    var call:Call?
    var callKitCompletionCallback: ((Bool)->Swift.Void?)? = nil
    var audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callOutgoing: Bool = false
    
    static var appName: String {
        get {
            return (Bundle.main.infoDictionary!["CFBundleName"] as? String) ?? "Define CFBundleName"
        }
    }
    
    public override init() {
        
        //isSpinning = false
        voipRegistry = PKPushRegistry.init(queue: DispatchQueue.main)
        let configuration = CXProviderConfiguration(localizedName: SwiftFlutterTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        if let callKitIcon = UIImage(named: "logo_white") {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }
        
        clients = UserDefaults.standard.object(forKey: kClientList)  as? [String:String] ?? [:]
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        //super.init(coder: aDecoder)
        super.init()
        
        callKitProvider.setDelegate(self, queue: nil)
        
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = Set([PKPushType.voIP])

        let appDelegate = UIApplication.shared.delegate
        guard let controller = appDelegate?.window??.rootViewController as? FlutterViewController else {
            fatalError("rootViewController is not type FlutterViewController")
        }
        let registrar = controller.registrar(forPlugin: "flutter_twilio_voice")
        if let unwrappedRegistrar = registrar {
            let eventChannel = FlutterEventChannel(name: "flutter_twilio_voice/events", binaryMessenger: unwrappedRegistrar.messenger())
            eventChannel.setStreamHandler(self)
        }
    }
    
    
    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
    }
    
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        
        let instance = SwiftFlutterTwilioVoicePlugin()
        let methodChannel = FlutterMethodChannel(name: "flutter_twilio_voice/messages", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "flutter_twilio_voice/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        
    }
    
    public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
        _result = result
        
        let arguments:Dictionary<String, AnyObject> = flutterCall.arguments as! Dictionary<String, AnyObject>;
        
        if flutterCall.method == "tokens" {
            guard let token = arguments["accessToken"] as? String else {return}
            self.accessToken = token
            if let deviceToken = deviceToken, let token = accessToken {
                self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:attempting to register with twilio", isError: false)
                TwilioVoice.register(accessToken: token, deviceToken: deviceToken) { (error) in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|ERROR|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    }
                    else {
                        self.sendPhoneCallEvents(description: "LOG|INFO|Successfully registered for VoIP push notifications.", isError: false)
                    }
                }
            } /*else if let deviceToken = arguments["deviceToken"] as? String, let token = accessToken {
                self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:attempting to register with twilio", isError: false)
                TwilioVoice.register(accessToken: token, deviceToken: deviceToken) { (error) in
                    if let error = error {
                        self.sendPhoneCallEvents(description: "LOG|ERROR|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    }
                    else {
                        self.sendPhoneCallEvents(description: "LOG|INFO|Successfully registered for VoIP push notifications.", isError: false)
                    }
                }
            }*/
        } else if flutterCall.method == "makeCall" {
            guard let callTo = arguments["To"] as? String else {return}
            guard let callFrom = arguments["From"] as? String else {return}
            self.callArgs = arguments
            self.callOutgoing = true
            if let accessToken = arguments["accessToken"] as? String{
                self.accessToken = accessToken
            }
            self.callTo = callTo
            self.identity = callFrom
            makeCall(to: callTo)
        }
        else if flutterCall.method == "muteCall"
        {
            if (self.call != nil) {
                let muted = self.call!.isMuted
                self.call!.isMuted = !muted
                guard let eventSink = eventSink else {
                    return
                }
                eventSink(!muted ? "Mute" : "Unmute")
            } else {
                let ferror: FlutterError = FlutterError(code: "MUTE_ERROR", message: "No call to be muted", details: nil)
                _result!(ferror)
            }
        }
        else if flutterCall.method == "toggleSpeaker"
        {
            guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {return}
            toggleAudioRoute(toSpeaker: speakerIsOn)
            guard let eventSink = eventSink else {
                return
            }
            eventSink(speakerIsOn ? "Speaker On" : "Speaker Off")
        }
        else if flutterCall.method == "isOnCall"
        {
            result(self.call != nil);
            return;
        }
        else if flutterCall.method == "sendDigits"
        {
            guard let digits = arguments["digits"] as? String else {return}
            if (self.call != nil) {
                self.call!.sendDigits(digits);
            }
        }
        /* else if flutterCall.method == "receiveCalls"
         {
         guard let clientIdentity = arguments["clientIdentifier"] as? String else {return}
         self.identity = clientIdentity;
         } */
        else if flutterCall.method == "holdCall" {
            if (self.call != nil) {
                
                let hold = self.call!.isOnHold
                self.call!.isOnHold = !hold
                guard let eventSink = eventSink else {
                    return
                }
                eventSink(!hold ? "Hold" : "Unhold")
            }
        }
        else if flutterCall.method == "answer" {
            // nuthin
        }
        else if flutterCall.method == "unregister" {
            guard let token = arguments["accessToken"] as? String else {return}
            guard let deviceToken = deviceToken else {
                return
            }
            self.unregisterTokens(token: token, deviceToken: deviceToken)
            
        }else if flutterCall.method == "hangUp"{
            if (self.call != nil && self.call?.state == .connected) {
                self.sendPhoneCallEvents(description: "LOG|INFO|hangUp method invoked", isError: false)
                self.userInitiatedDisconnect = true
                performEndCallAction(uuid: self.call!.uuid!)
                //self.toggleUIState(isEnabled: false, showCallControl: false)
            }
        }else if flutterCall.method == "registerClient"{
            guard let clientId = arguments["id"] as? String, let clientName =  arguments["name"] as? String else {return}
            if clients[clientId] == nil || clients[clientId] != clientName{
                clients[clientId] = clientName
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
            
        }else if flutterCall.method == "unregisterClient"{
            guard let clientId = arguments["id"] as? String else {return}
            clients.removeValue(forKey: clientId)
            UserDefaults.standard.set(clients, forKey: kClientList)
            
        }else if flutterCall.method == "defaultCaller"{
            guard let caller = arguments["defaultCaller"] as? String else {return}
            defaultCaller = caller
            if(clients["defaultCaller"] == nil || clients["defaultCaller"] != defaultCaller){
                clients["defaultCaller"] = defaultCaller
                UserDefaults.standard.set(clients, forKey: kClientList)
            }
        }else if flutterCall.method == "callerIdCustomParameterKey"{
            guard let value = arguments["key"] as? String else {return}
            callerIdCustomParameterKey = value
        }else if flutterCall.method == "hasMicPermission" {
            result(true) ///do nuthin
            return
        }else if flutterCall.method == "requestMicPermission"{
            result(true)///do nuthin
            return
        }
        result(true)
    }
    
    func makeCall(to: String)
    {
        if (self.call != nil && self.call?.state == .connected) {
            self.userInitiatedDisconnect = true
            performEndCallAction(uuid: self.call!.uuid!)            
        } else {
            let uuid = UUID()
            
            self.checkRecordPermission { (permissionGranted) in
                if (!permissionGranted) {
                    let alertController: UIAlertController = UIAlertController(title: String(format:  NSLocalizedString("mic_permission_title", comment: "") , SwiftFlutterTwilioVoicePlugin.appName),
                                                                               message: NSLocalizedString( "mic_permission_subtitle", comment: ""),
                                                                               preferredStyle: .alert)
                    
                    let continueWithMic: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_continue_no_mic", comment: ""),
                                                                       style: .default,
                                                                       handler: { (action) in
                                                                        self.performStartCallAction(uuid: uuid, handle: to)
                                                                       })
                    alertController.addAction(continueWithMic)
                    
                    let goToSettings: UIAlertAction = UIAlertAction(title:NSLocalizedString("btn_settings", comment: ""),
                                                                    style: .default,
                                                                    handler: { (action) in
                                                                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                                  options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: false],
                                                                                                  completionHandler: nil)
                                                                    })
                    alertController.addAction(goToSettings)
                    
                    let cancel: UIAlertAction = UIAlertAction(title: NSLocalizedString("btn_cancel", comment: ""),
                                                              style: .cancel,
                                                              handler: { (action) in
                                                                //self.toggleUIState(isEnabled: true, showCallControl: false)
                                                                //self.stopSpin()
                                                              })
                    alertController.addAction(cancel)
                    guard let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() else {
                        return
                    }
                    currentViewController.present(alertController, animated: true, completion: nil)
                    
                } else {
                    self.performStartCallAction(uuid: uuid, handle: to)
                }
            }
        }
    }
    
    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case AVAudioSessionRecordPermission.granted:
            // Record permission already granted.
            completion(true)
            break
        case AVAudioSessionRecordPermission.denied:
            // Record permission denied.
            completion(false)
            break
        case AVAudioSessionRecordPermission.undetermined:
            // Requesting record permission.
            // Optional: pop up app dialog to let the users know if they want to request.
            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                completion(granted)
            })
            break
        default:
            completion(false)
            break
        }
    }
    
    
    // MARK: PKPushRegistryDelegate
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:didUpdatePushCredentials:forType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        guard deviceToken != credentials.token else { return }

        let deviceToken = credentials.token
        
        self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:attempting to register with twilio", isError: false)
        if let token = accessToken {
            TwilioVoice.register(accessToken: token, deviceToken: deviceToken) { (error) in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|ERROR|An error occurred while registering: \(error.localizedDescription)", isError: false)
                    self.sendPhoneCallEvents(description: "DEVICETOKEN|\(String(decoding: deviceToken, as: UTF8.self))", isError: false)
                }
                else {
                    self.sendPhoneCallEvents(description: "LOG|INFO|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        }
        self.deviceToken = deviceToken

    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:didInvalidatePushTokenForType:", isError: false)
        
        if (type != .voIP) {
            return
        }
        
        self.unregister()
    }
    
    func unregister() {
        
        guard let deviceToken = deviceToken, let token = accessToken else {
            return
        }
        
        self.unregisterTokens(token: token, deviceToken: deviceToken)
    }
    
    func unregisterTokens(token: String, deviceToken: Data) {
        TwilioVoice.unregister(accessToken: token, deviceToken: deviceToken) { (error) in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|ERROR|An error occurred while unregistering: \(error.localizedDescription)", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|INFO|Successfully unregistered from VoIP push notifications.", isError: false)
            }
        }
        UserDefaults.standard.removeObject(forKey: kCachedDeviceToken)
    }
    
    /**
     * Try using the `pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:` method if
     * your application is targeting iOS 11. According to the docs, this delegate method is deprecated by Apple.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.sendPhoneCallEvents(description: "LOG|INFO|pushRegistry:didReceiveIncomingPushWithPayload:forType:", isError: false)
        
        if (type == PKPushType.voIP) {
            TwilioVoice.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
    }
    
    /**
     * This delegate method is available on iOS 11 and above. Call the completion handler once the
     * notification payload is passed to the `TwilioVoice.handleNotification()` method.
     */
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:completion:", isError: false)
        // Save for later when the notification is properly handled.
//        self.incomingPushCompletionCallback = completion
        
        if (type == PKPushType.voIP) {
            TwilioVoice.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        }
        
        if let version = Float(UIDevice.current.systemVersion), version < 13.0 {
            // Save for later when the notification is properly handled.
            self.incomingPushCompletionCallback = completion
        } else {
            /**
             * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
             * CallKit and fulfill the completion before exiting this callback method.
             */
            completion()
        }
    }
    
    func incomingPushHandled() {
        if let completion = self.incomingPushCompletionCallback {
            self.incomingPushCompletionCallback = nil
            completion()
        }
    }
    
    // MARK: TVONotificaitonDelegate
    public func callInviteReceived(callInvite: CallInvite) {
        self.sendPhoneCallEvents(description: "LOG|INFO|callInviteReceived:", isError: false)
        
        var from:String = callInvite.from ?? defaultCaller
        from = from.replacingOccurrences(of: "client:", with: "")
        
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(callInvite.to)|Incoming", isError: false)
        reportIncomingCall(from: from, uuid: callInvite.uuid, callerId: callInvite.customParameters?[self.callerIdCustomParameterKey])
        self.callInvite = callInvite
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|INFO|cancelledCallInviteCanceled:", isError: false)
        
        if (self.callInvite == nil) {
            self.sendPhoneCallEvents(description: "LOG|WARN|No pending call invite", isError: false)
            return
        }
        
        if let ci = self.callInvite {
            performEndCallAction(uuid: ci.uuid)
        }
    }
    
    // MARK: TVOCallDelegate
    public func callDidStartRinging(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = (call.from ?? self.identity)
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(to)|\(direction)", isError: false)
        
        //self.placeCallButton.setTitle("Ringing", for: .normal)
    }
    
    public func callDidConnect(call: Call) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = (call.from ?? self.identity)
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)
        
        if let callKitCompletionCallback = callKitCompletionCallback {
            callKitCompletionCallback(true)
        }
        
        toggleAudioRoute(toSpeaker: false)
    }
    
    public func call(call: Call, isReconnectingWithError error: Error) {
        self.sendPhoneCallEvents(description: "LOG|INFO|call:isReconnectingWithError:", isError: false)
        
    }
    
    public func callDidReconnect(call: Call) {
        self.sendPhoneCallEvents(description: "LOG|INFO|callDidReconnect:", isError: false)
    }
    
    public func callDidFailToConnect(call: Call, error: Error) {
        self.sendPhoneCallEvents(description: "LOG|ERROR|Call failed to connect: \(error.localizedDescription)", isError: false)
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        if(error.localizedDescription.contains("Access Token expired")){
            self.sendPhoneCallEvents(description: "DEVICETOKEN", isError: false)
        }
        if let completion = self.callKitCompletionCallback {
            completion(false)
        }
        
        
        callKitProvider.reportCall(with: call.uuid!, endedAt: Date(), reason: CXCallEndedReason.failed)
        callDisconnected()
    }
    
    public func callDidDisconnect(call: Call, error: Error?) {
        self.sendPhoneCallEvents(description: "Call Ended", isError: false)
        if let error = error {
            self.sendPhoneCallEvents(description: "Call Failed: \(error.localizedDescription)", isError: true)
        }
        
        if !self.userInitiatedDisconnect {
            var reason = CXCallEndedReason.remoteEnded
            self.sendPhoneCallEvents(description: "LOG|INFO|User initiated disconnect", isError: false)
            if error != nil {
                reason = .failed
            }
            
            self.callKitProvider.reportCall(with: call.uuid!, endedAt: Date(), reason: reason)
        }
        
        callDisconnected()
    }
    
    func callDisconnected() {
        self.sendPhoneCallEvents(description: "LOG|INFO|Call Disconnected", isError: false)
        if (self.call != nil) {
            
            self.sendPhoneCallEvents(description: "LOG|INFO|Setting call to nil", isError: false)
            self.call = nil
        }
        if (self.callInvite != nil) {
            self.callInvite = nil
        }
        
        self.callOutgoing = false
        self.userInitiatedDisconnect = false
        
    }
    
    
    // MARK: AVAudioSession
    func toggleAudioRoute(toSpeaker: Bool) {
        // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
        audioDevice.block = {
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            do {
                if (toSpeaker) {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                } else {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                }
            } catch {
                self.sendPhoneCallEvents(description: "LOG|ERROR|\(error.localizedDescription)", isError: false)
            }
        }
        audioDevice.block()
    }
    
    // MARK: CXProviderDelegate
    public func providerDidReset(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|INFO|providerDidReset:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func providerDidBegin(_ provider: CXProvider) {
        self.sendPhoneCallEvents(description: "LOG|INFO|providerDidBegin", isError: false)
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:didActivateAudioSession:", isError: false)
        audioDevice.isEnabled = true
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:didDeactivateAudioSession:", isError: false)
        audioDevice.isEnabled = false
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:timedOutPerformingAction:", isError: false)
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:performStartCallAction:", isError: false)
        
        
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        
        self.performVoiceCall(uuid: action.callUUID, client: "") { (success) in
            if (success) {
                self.sendPhoneCallEvents(description: "LOG|INFO|provider:performAnswerVoiceCall() successful", isError: false)
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            } else {
                self.sendPhoneCallEvents(description: "LOG|WARN|provider:performVoiceCall() failed", isError: false)
            }
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:performAnswerCallAction:", isError: false)
        
        
        self.performAnswerVoiceCall(uuid: action.callUUID) { (success) in
            if success {
                self.sendPhoneCallEvents(description: "LOG|INFO|provider:performAnswerVoiceCall() successful", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|WARN|provider:performAnswerVoiceCall() failed:", isError: false)
            }
        }
        
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:performEndCallAction:", isError: false)
        
        
        if (self.callInvite != nil) {
            self.sendPhoneCallEvents(description: "LOG|INFO|provider:performEndCallAction: rejecting call", isError: false)
            self.callInvite?.reject()
            self.callInvite = nil
        }else if let call = self.call {
            self.sendPhoneCallEvents(description: "LOG|INFO|provider:performEndCallAction: disconnecting call", isError: false)
            call.disconnect()
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:performSetHeldAction:", isError: false)
        if let call = self.call {
            call.isOnHold = action.isOnHold
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.sendPhoneCallEvents(description: "LOG|INFO|provider:performSetMutedAction:", isError: false)
        
        if let call = self.call {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    // MARK: Call Kit Actions
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|ERROR|StartCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                return
            }
            
            self.sendPhoneCallEvents(description: "LOG|INFO|StartCallAction transaction request successful", isError: false)
            
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.localizedCallerName = self.clients[handle] ?? self.clients["defaultCaller"] ?? self.defaultCaller
            callUpdate.supportsDTMF = false
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            
            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
        }
    }
    
    func reportIncomingCall(from: String, uuid: UUID, callerId: String?) {
        let callHandle = CXHandle(type: .generic, value: from)
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.localizedCallerName = callerId ?? clients[from] ?? self.clients["defaultCaller"] ?? defaultCaller
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "LOG|ERROR|Failed to report incoming call successfully: \(error.localizedDescription).", isError: false)
            } else {
                self.sendPhoneCallEvents(description: "LOG|INFO|Incoming call successfully reported.", isError: false)
            }
        }
    }
    
    func performEndCallAction(uuid: UUID) {
        
        self.sendPhoneCallEvents(description: "LOG|INFO|performEndCallAction method invoked", isError: false)
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        callKitCallController.request(transaction) { error in
            if let error = error {
                self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription).", isError: true)
            } else {
                self.sendPhoneCallEvents(description: "Call Ended", isError: false)
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
        guard let token = accessToken else {
            completionHandler(false)
            return
        }
        
        let connectOptions: ConnectOptions = ConnectOptions(accessToken: token) { (builder) in
            builder.params = ["To": self.callTo]
            for (key, value) in self.callArgs {
                if (key != "To" && key != "From") {
                    builder.params[key] = "\(value)"
                }
            }
            builder.uuid = uuid
        }
        let theCall = TwilioVoice.connect(options: connectOptions, delegate: self)
        self.call = theCall
        self.callKitCompletionCallback = completionHandler
    }
    
    func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
        if let ci = self.callInvite {
            let acceptOptions: AcceptOptions = AcceptOptions(callInvite: ci) { (builder) in
                builder.uuid = ci.uuid
            }
            self.sendPhoneCallEvents(description: "LOG|INFO|performAnswerVoiceCall: answering call", isError: false)
            let theCall = ci.accept(options: acceptOptions, delegate: self)
            eventSink?("Answer|\(theCall.from!)|\(theCall.to!)")
            self.call = theCall
            self.callKitCompletionCallback = completionHandler
            self.callInvite = nil
            
            guard #available(iOS 13, *) else {
                self.incomingPushHandled()
                return
            }
        } else {
            self.sendPhoneCallEvents(description: "LOG|WARN|No CallInvite matches the UUID", isError: false)
        }
    }
    
    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(CallDelegate.callDidDisconnect),
            name: NSNotification.Name(rawValue: "PhoneCallEvent"),
            object: nil)
        
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }
    
    private func sendPhoneCallEvents(description: String, isError: Bool) {
        NSLog(description)
        guard let eventSink = eventSink else {
            return
        }
        
        if isError
        {
            eventSink(FlutterError(code: "unavailable",
                                   message: description,
                                   details: nil))
        }
        else
        {
            eventSink(description)
        }
    }
    
    
    
}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else {
            return nil
        }
        return topViewController(for: rootViewController)
    }
    
    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else {
            return nil
        }
        guard let presentedViewController = rootViewController.presentedViewController else {
            return rootViewController
        }
        switch presentedViewController {
        case is UINavigationController:
            let navigationController = presentedViewController as! UINavigationController
            return topViewController(for: navigationController.viewControllers.last)
        case is UITabBarController:
            let tabBarController = presentedViewController as! UITabBarController
            return topViewController(for: tabBarController.selectedViewController)
        default:
            return topViewController(for: presentedViewController)
        }
    }
}
