import AppKit
import Carbon.HIToolbox
import Foundation

/// Un atajo de teclado que funciona con cualquier aplicacion al frente.
///
/// Hasta ahora la pluma de la barra de menu era el unico control, y eso tiene un
/// costo que ya se pago: el 13 de agosto el daemon se cayo justo al empezar una
/// reunion, y sin icono no habia forma de grabar. Un atajo tambien resuelve el
/// caso comun, que es acordarse de grabar cuando la reunion ya empezo y uno esta
/// en otra ventana.
///
/// Se usa `RegisterEventHotKey` de Carbon y no un monitor global de NSEvent a
/// proposito: el monitor exige permiso de Accesibilidad, que es el permiso de
/// leer todo lo que el usuario teclea en cualquier aplicacion. Pedirlo para
/// escuchar una combinacion es desproporcionado, y ademas macOS lo revoca en
/// cada actualizacion. Carbon registra la combinacion en el sistema sin ver
/// nada mas.
final class AtajoGlobal {
    /// Combinaciones registradas, por identificador. Carbon devuelve un
    /// identificador numerico en el evento y no hay donde colgar contexto, asi
    /// que la traduccion vive aca.
    ///
    /// Va en una clase con candado en vez de variables estaticas porque el
    /// compilador no acepta estado global mutable sin proteccion, y marcar todo
    /// como del hilo principal chocaria con deinit, que no puede estar aislado.
    private final class Registro: @unchecked Sendable {
        private let candado = NSLock()
        private var porId: [UInt32: AtajoGlobal] = [:]
        private var proximo: UInt32 = 1
        private var manejadorPuesto = false

        func nuevoId() -> UInt32 {
            candado.lock(); defer { candado.unlock() }
            proximo += 1
            return proximo - 1
        }

        func anotar(_ id: UInt32, _ atajo: AtajoGlobal?) {
            candado.lock(); defer { candado.unlock() }
            porId[id] = atajo
        }

        func buscar(_ id: UInt32) -> AtajoGlobal? {
            candado.lock(); defer { candado.unlock() }
            return porId[id]
        }

        /// Devuelve true la primera vez, para instalar el despachador una sola vez.
        func reclamarInstalacion() -> Bool {
            candado.lock(); defer { candado.unlock() }
            if manejadorPuesto { return false }
            manejadorPuesto = true
            return true
        }
    }

    private static let registro = Registro()

    private let identificador: UInt32
    private let alPulsar: () -> Void
    private var referencia: EventHotKeyRef?

    /// La combinacion tal como se escribe en la configuracion, para poder
    /// mostrarla en el menu y en el doctor.
    let descripcion: String

    /// Registra la combinacion. Devuelve nil si no se pudo, que en la practica
    /// significa que otra aplicacion ya la tiene tomada.
    init?(_ combinacion: String, alPulsar: @escaping () -> Void) {
        guard let (modificadores, tecla) = Self.interpretar(combinacion) else { return nil }
        self.identificador = Self.registro.nuevoId()
        self.alPulsar = alPulsar
        self.descripcion = combinacion

        Self.instalarManejador()

        let id = EventHotKeyID(signature: OSType(0x71_75_6C_6C), id: identificador)  // 'qull'
        var ref: EventHotKeyRef?
        let estado = RegisterEventHotKey(
            UInt32(tecla), UInt32(modificadores), id, GetEventDispatcherTarget(), 0, &ref)
        guard estado == noErr, let ref else { return nil }

        self.referencia = ref
        Self.registro.anotar(identificador, self)
    }

    deinit {
        if let referencia { UnregisterEventHotKey(referencia) }
        Self.registro.anotar(identificador, nil)
    }

    /// Instala una sola vez el despachador de Carbon para todas las
    /// combinaciones.
    private static func instalarManejador() {
        guard registro.reclamarInstalacion() else { return }

        var tipo = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, evento, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(
                evento, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon despacha en el hilo principal, que es donde vive todo lo
            // que toca la interfaz y la grabacion.
            let atajo = AtajoGlobal.registro.buscar(id.id)
            MainActor.assumeIsolated { atajo?.alPulsar() }
            return noErr
        }, 1, &tipo, nil, nil)
    }

    /// Traduce "cmd+alt+r" a la combinacion que espera Carbon.
    ///
    /// Se aceptan los nombres que la gente escribe sin pensarlo: cmd o command,
    /// alt u option, ctrl o control, shift. El orden no importa y las mayusculas
    /// tampoco.
    static func interpretar(_ combinacion: String) -> (modificadores: Int, tecla: Int)? {
        var modificadores = 0
        var tecla: Int?

        for parte in combinacion.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" }) {
            switch parte.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta": modificadores |= cmdKey
            case "alt", "option", "opt": modificadores |= optionKey
            case "ctrl", "control": modificadores |= controlKey
            case "shift": modificadores |= shiftKey
            case let otra:
                guard let codigo = codigos[otra] else { return nil }
                tecla = codigo
            }
        }
        // Sin modificador no se registra: una letra sola secuestraria el teclado
        // de todo el sistema.
        guard let tecla, modificadores != 0 else { return nil }
        return (modificadores, tecla)
    }

    /// La combinacion como la escribe AppKit, para mostrarla en el menu: la
    /// tecla sola y la mascara de modificadores aparte.
    var paraElMenu: (tecla: String, modificadores: NSEvent.ModifierFlags)? {
        var mascara: NSEvent.ModifierFlags = []
        var tecla: String?
        for parte in descripcion.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" }) {
            switch parte.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta": mascara.insert(.command)
            case "alt", "option", "opt": mascara.insert(.option)
            case "ctrl", "control": mascara.insert(.control)
            case "shift": mascara.insert(.shift)
            case let otra: tecla = otra == "space" || otra == "espacio" ? " " : otra
            }
        }
        guard let tecla else { return nil }
        return (tecla, mascara)
    }

    /// Codigos de tecla virtuales de macOS. Solo letras, digitos y espacio: son
    /// las que alguien elige para un atajo, y una tabla mas larga es mas
    /// superficie para equivocarse sin que nadie la use.
    private static let codigos: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "espacio": kVK_Space,
    ]
}
