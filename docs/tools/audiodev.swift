import Foundation
import CoreAudio
// audiodev list | get | set <uid>
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}
func rate(_ o: AudioObjectID) -> Double { var a = addr(kAudioDevicePropertyNominalSampleRate); var r = 0.0; var size = UInt32(8); AudioObjectGetPropertyData(o, &a, 0, nil, &size, &r); return r }
func streams(_ o: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
    var a = addr(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4); AudioObjectGetPropertyData(o, &a, 0, nil, &size, &ids); return ids
}
func fmt(_ s: AudioObjectID) -> String {
    var a = addr(kAudioStreamPropertyVirtualFormat); var d = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(s, &a, 0, nil, &size, &d) == noErr else { return "?" }
    let inter = (d.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    return "\(Int(d.mSampleRate)) Hz/\(d.mChannelsPerFrame) ch\(inter ? " entrelacé" : "")/\(d.mBytesPerFrame) o/trame"
}
func defaultOut() -> AudioObjectID { var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var id = AudioObjectID(0); var size = UInt32(4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id); return id }
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids); return ids
}
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "list" {
case "get": print(str(defaultOut(), kAudioDevicePropertyDeviceUID))
case "rate":
    guard args.count > 3, let hz = Double(args[3]) else { exit(2) }
    guard let dev = devices().first(where: { str($0, kAudioDevicePropertyDeviceUID) == args[2] }) else { print("UID inconnu"); exit(1) }
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r = hz
    let st = AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &r); print(st == noErr ? "ok \(Int(rate(dev))) Hz" : "erreur \(st)")
case "set":
    guard args.count > 2 else { exit(2) }
    guard let dev = devices().first(where: { str($0, kAudioDevicePropertyDeviceUID) == args[2] }) else { print("UID inconnu"); exit(1) }
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var id = dev
    let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &id); print(st == noErr ? "ok" : "erreur \(st)")
default:
    let d = defaultOut()
    for id in devices() {
        let outs = streams(id, kAudioDevicePropertyScopeOutput), ins = streams(id, kAudioDevicePropertyScopeInput)
        print("\(id == d ? "*" : " ") [\(id)] \(str(id, kAudioObjectPropertyName)) | uid \(str(id, kAudioDevicePropertyDeviceUID)) | \(Int(rate(id))) Hz | out \(outs.map(fmt)) | in \(ins.count) flux")
    }
}
