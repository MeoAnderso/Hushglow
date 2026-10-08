import CoreAudio
import Foundation

/// Tracks whether sound is going to a display that has no volume control of its own. That is
/// the only case where the volume keys are redirected to the display over DDC.
@MainActor
final class AudioRoute {
    private(set) var outputIsDisplay = false
    private var isListening = false

    /// Follows changes of the default output device; event-driven, no polling.
    func startListening() {
        guard !isListening else { return }
        isListening = true
        var address = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) {
            [weak self] _, _ in
            let route = self
            MainActor.assumeIsolated { route?.refresh() }
        }
        refresh()
    }

    func refresh() {
        outputIsDisplay =
            Self.defaultOutputDevice().map { Self.isDisplayTransport($0) && !Self.hasVolumeControl($0) } ?? false
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != AudioDeviceID(kAudioObjectUnknown) ? device : nil
    }

    private static func isDisplayTransport(_ device: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }

    private static func hasVolumeControl(_ device: AudioDeviceID) -> Bool {
        // The main element, then the left and right channels.
        (0...2).contains { element in
            var address = propertyAddress(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement(element)
            )
            return AudioObjectHasProperty(device, &address)
        }
    }
}
