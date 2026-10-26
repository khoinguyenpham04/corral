import Carbon
import CorralUI

/// One global shortcut through Carbon's hot key API, which needs no Accessibility permission.
@MainActor
final class Hotkeys {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: () -> Void = {}

    func register(_ shortcut: Shortcut?, action: @escaping () -> Void) {
        unregister()
        self.action = action
        guard let shortcut else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                    MainActor.assumeIsolated { hotkeys.action() }
                    return noErr
                },
                1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
            )
        }
        let id = EventHotKeyID(signature: OSType(0x4352_4C4C), id: 1)  // 'CRLL'
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
