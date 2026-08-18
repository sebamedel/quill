import CoreAudio
import Foundation

/// ¿Hay otra aplicacion usando el microfono en este momento?
///
/// Existe por un incidente concreto: con la cancelacion de eco encendida, quill
/// toma el microfono y le cambia la configuracion al dispositivo, que es
/// compartido. La videollamada que estaba en curso siguio recibiendo audio,
/// pero degradado, y del otro lado se escuchaba lejos y bajo. El sintoma es
/// peor que un fallo limpio: nadie sospecha de la grabacion, se culpa a la red
/// o al microfono, y se pierde media reunion averiguando.
///
/// Preguntar quien tiene el microfono no requiere permiso: se consulta el
/// estado de los procesos de audio, no se escucha nada.
enum OtrosCapturando {
    /// Los PID que estan capturando entrada, sin contar el proceso propio.
    static func pids() -> [pid_t] {
        var lista = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var tam: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &lista, 0, nil, &tam) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(tam) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &lista, 0, nil, &tam, &ids) == noErr else { return [] }

        let propio = getpid()
        var encontrados: [pid_t] = []
        for id in ids {
            var capturando = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var activo: UInt32 = 0
            var t = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &capturando, 0, nil, &t, &activo) == noErr,
                  activo != 0 else { continue }

            var pidDir = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var tp = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &pidDir, 0, nil, &tp, &pid) == noErr,
               pid != propio {
                encontrados.append(pid)
            }
        }
        return encontrados
    }

    static var hayAlguno: Bool { !pids().isEmpty }
}
