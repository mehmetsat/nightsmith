import Carbon.HIToolbox

/// Global ⌃⌥⌘ hot keys through Carbon's hot key API. Registered hot keys work from any app without extra permission.
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    /// Registers ⌃⌥⌘ plus `keyCode`. `id` tells the shared event handler which action to run.
    static func register(keyCode: Int, id: UInt32, _ action: @escaping () -> Void) {
        handlers[id] = action

        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                DispatchQueue.main.async { HotKey.handlers[pressed.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5342_5858), id: id) // 'SBXX'
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
