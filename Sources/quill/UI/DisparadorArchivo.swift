import Foundation

/// Un archivo que hace de boton: cuando aparece, la grabacion arranca o para.
///
/// Existe porque quill se maneja con la barra de menu y con un atajo global, y
/// las dos puertas suponen a alguien con las manos en el teclado. Para que otra
/// cosa del computador pueda empezar una grabacion (el aviso de que empezo una
/// reunion agendada, un acceso rapido, lo que sea) la alternativa era simular
/// la pulsacion del atajo, y para eso macOS exige permiso de Accesibilidad, que
/// es permitirle a quien lo tenga controlar el computador entero. Un archivo
/// que aparece en la carpeta de configuracion del propio programa no necesita
/// permiso de nada y hace exactamente una cosa.
///
/// El archivo se borra antes de actuar: si algo falla despues, no queda un
/// disparo pendiente que se repita en el siguiente vistazo. El contenido no se
/// lee, solo importa que este.
@MainActor
final class DisparadorArchivo {
    private let ruta: URL
    private var reloj: DispatchSourceTimer?

    init(ruta: URL, cada intervalo: TimeInterval = 1, alDisparar: @escaping () -> Void) {
        self.ruta = ruta
        // Se mira cada segundo en vez de vigilar la carpeta con el sistema de
        // archivos: la carpeta puede no existir todavia, y un vistazo por
        // segundo a una ruta no cuesta nada frente a estar grabando audio.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + intervalo, repeating: intervalo)
        timer.setEventHandler { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.ruta.path)
            else { return }
            try? FileManager.default.removeItem(at: self.ruta)
            alDisparar()
        }
        timer.resume()
        reloj = timer
    }

    deinit {
        reloj?.cancel()
    }
}
