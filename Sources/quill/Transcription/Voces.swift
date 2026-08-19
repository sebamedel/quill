import FluidAudio
import Foundation

/// Quien hablo cuando, dentro de una pista.
///
/// quill graba dos pistas y por eso separar al que graba del resto sale gratis
/// en una reunion remota: cada voz llega por su canal. En una reunion presencial
/// o por telefono con altavoz eso se cae, porque todas las voces entran por el
/// microfono, y la minuta termina escribiendo que no puede saber quien dijo
/// cada cosa. Esto separa las voces dentro de una misma pista.
///
/// Deliberadamente NO pone nombres. Devuelve "voz 1", "voz 2", y el nombre se
/// asigna despues desde el visor, donde hay una persona que sabe cual es cual.
/// Adivinar el nombre aqui seria inventar.
struct Voces: Sendable {
    /// Un tramo continuo de una sola voz, en segundos desde el inicio de la pista.
    struct Turno: Sendable, Codable {
        let voz: String
        let inicio: Double
        let fin: Double
        /// Confianza del propio diarizador en el tramo, tal como la entrega.
        let calidad: Double
    }

    let turnos: [Turno]

    /// La huella de cada voz: el promedio de lo que el modelo oyo en sus
    /// tramos, en un vector.
    ///
    /// Es lo unico de una grabacion que sirve en la siguiente. Los numeros de
    /// voz no: "voz 4" es el cuarto grupo que se formo en ESTA pista y en la
    /// proxima reunion sera otra persona. La huella, en cambio, es de la voz,
    /// asi que comparada contra las que ya tienen nombre dice a quien se
    /// parece. Sin esto hay que volver a decir quien es quien en cada reunion.
    var huellas: [String: [Float]] = [:]

    /// Cuanto habla cada voz, en segundos. Es el numero que delata un corte
    /// malo: una conversacion de dos que sale 99/1 no encontro al segundo,
    /// aunque declare tres voces.
    var reparto: [(voz: String, segundos: Double)] {
        var suma: [String: Double] = [:]
        for t in turnos { suma[t.voz, default: 0] += t.fin - t.inicio }
        return suma.sorted { $0.value > $1.value }.map { (voz: $0.key, segundos: $0.value) }
    }

    /// Las voces que hablan lo suficiente para ser una persona y no un ruido.
    ///
    /// El diarizador crea una voz nueva cada vez que un tramo corto no se
    /// parece a lo que ya vio, asi que una reunion de dos puede declarar
    /// dieciocho: casi todas con uno o dos segundos, que son toses, muebles y
    /// solapamientos. Se queda con las que pasan el minimo.
    func vocesReales(minimoSegundos: Double = 15) -> [String] {
        reparto.filter { $0.segundos >= minimoSegundos }.map(\.voz)
    }
}

/// Corre la diarizacion de FluidAudio sobre una pista.
///
/// Los modelos pesan 14 MB y se quedan en la cache de FluidAudio; diarizar
/// corre a unas 130 veces el tiempo real en Apple Silicon, asi que es barato
/// frente a la transcripcion misma.
actor Diarizador {
    /// Umbral de agrupamiento.
    ///
    /// Barrido de 0,6 a 0,8 contra dos grabaciones con respuesta conocida, una
    /// de dos personas en una sala y una de una sola persona hablando a su
    /// microfono en una reunion remota:
    ///
    ///     umbral   una persona sola   dos en una sala
    ///     0,60     4 voces            2 voces
    ///     0,65     2 voces            1 voz
    ///     0,70     2 voces            1 voz
    ///     0,80     2 voces            1 voz
    ///
    /// Ninguno acierta en los dos casos: el unico que separa a dos personas es
    /// el mismo que parte en cuatro a una persona sola. No es un problema de
    /// calibracion, el agrupador no es confiable en grabaciones de sala. Por eso
    /// se elige 0,60 y se limita su uso al caso de la derecha, que es el que hoy
    /// esta roto; ver el comentario de la tuberia.
    ///
    /// Lo que corresponde para mejorarlo no es mover este numero, es registrar
    /// la voz del titular una vez y comparar contra ella (`enrollSpeaker`):
    /// reconocer una voz conocida es un problema mucho mas facil que agrupar
    /// voces desconocidas.
    static let umbralPorOmision: Float = 0.6

    /// Los modelos se cargan en cada llamada a proposito: `initialize` los
    /// consume, asi que guardarlos en el actor solo alcanzaria para la primera
    /// pista y la segunda quedaria sin separar. Cargarlos de la cache cuesta
    /// poco frente a transcribir.
    func diarizar(_ audio: URL, umbral: Float = Diarizador.umbralPorOmision) async throws -> Voces {
        let modelos = try await DiarizerModels.downloadIfNeeded()
        let muestras = try AudioConverter().resampleAudioFile(audio)
        var config = DiarizerConfig.default
        config.clusteringThreshold = umbral

        let manager = DiarizerManager(config: config)
        // initialize consume los modelos, asi que hay que rehacerlos para la
        // pista siguiente. Cargarlos de la cache es rapido; la descarga fue una
        // sola vez.
        manager.initialize(models: modelos)

        let resultado = try manager.performCompleteDiarization(muestras)
        manager.cleanup()

        return Voces(
            turnos: resultado.segments.map {
                Voces.Turno(
                    voz: "voz \($0.speakerId)",
                    inicio: Double($0.startTimeSeconds),
                    fin: Double($0.endTimeSeconds),
                    calidad: Double($0.qualityScore)
                )
            },
            huellas: Diarizador.huellas(de: resultado.segments)
        )
    }

    /// Una huella por voz, promediando las de sus tramos.
    ///
    /// El promedio va pesado por lo que dura cada tramo: medio segundo de un
    /// "ya" describe una voz mucho peor que veinte segundos de explicacion, y
    /// contarlos igual acerca todas las huellas entre si. Al final se
    /// normaliza, que es lo que deja comparar dos huellas por el angulo entre
    /// ellas sin que importe el volumen.
    static func huellas(de segmentos: [TimedSpeakerSegment]) -> [String: [Float]] {
        let limpios = segmentos.filter { s in
            !segmentos.contains { otro in
                otro.speakerId != s.speakerId
                    && otro.startTimeSeconds < s.endTimeSeconds + aire
                    && otro.endTimeSeconds > s.startTimeSeconds - aire
            }
        }
        // Con los limpios cuando alcanzan, y con todos cuando no: una voz de
        // veinte segundos que siempre habla encima de otra igual tiene que
        // dejar huella, aunque peor.
        var suma = promedios(de: limpios)
        for (voz, v) in promedios(de: segmentos) where suma[voz] == nil { suma[voz] = v }
        return suma
    }

    /// Un tramo con otra voz pegada a menos de esto no describe a nadie: lo que
    /// suena ahi son dos personas, y el promedio queda a medio camino entre las
    /// dos. Es la misma razon por la que el visor no lo usa como muestra.
    private static let aire: Float = 0.4

    private static func promedios(de segmentos: [TimedSpeakerSegment]) -> [String: [Float]] {
        var suma: [String: [Float]] = [:]
        var largo = 0
        for s in segmentos where !s.embedding.isEmpty {
            let voz = "voz \(s.speakerId)"
            let peso = max(s.endTimeSeconds - s.startTimeSeconds, 0.01)
            if largo == 0 { largo = s.embedding.count }
            guard s.embedding.count == largo else { continue }
            var acumulado = suma[voz] ?? Array(repeating: Float(0), count: largo)
            for i in 0..<largo { acumulado[i] += s.embedding[i] * peso }
            suma[voz] = acumulado
        }
        return suma.mapValues { normalizada($0) }
    }

    /// El mismo vector con largo uno. Dos huellas normalizadas se comparan
    /// multiplicandolas: cuanto mas cerca de uno, mas se parecen.
    static func normalizada(_ v: [Float]) -> [Float] {
        let norma = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norma > 0 ? v.map { $0 / norma } : v
    }

}

extension Voces {
    /// Un cambio de voz que dura menos que esto no es un cambio de voz.
    ///
    /// El diarizador se equivoca en tramos muy cortos, y el sintoma es una
    /// palabra suelta atribuida al otro en medio de una frase ajena. Nadie
    /// interrumpe para decir media palabra y devolver el turno.
    private static let turnoMinimo: Double = 0.7

    /// Reparte los segmentos de una pista entre las voces que encontro.
    ///
    /// El corte se decide palabra por palabra, no por segmento: un segmento de
    /// transcripcion dura unos cinco segundos y un turno de conversacion dos,
    /// asi que elegir una sola voz por segmento pega en la misma frase lo que
    /// dijeron dos personas. Cuando el motor no entrega marcas por palabra
    /// (los que trabajan por ventanas largas no las tienen) se cae a asignar el
    /// segmento entero a la voz que mas lo cubre, que es lo mejor disponible.
    ///
    /// Las voces que no llegan al minimo se descartan antes de repartir: son
    /// toses y solapamientos, y arrastrarlas parte frases sanas en dos.
    func repartir(_ segmentos: [TranscriptSegment]) -> [(voz: String?, segmento: TranscriptSegment)] {
        let reales = Set(vocesReales())
        let utiles = turnos.filter { reales.contains($0.voz) }
        guard !utiles.isEmpty else { return segmentos.map { (voz: nil, segmento: $0) } }

        // Los segmentos sin marcas de palabra no se pueden partir; se resuelven
        // por solape y no entran al resto del procedimiento.
        guard segmentos.contains(where: { !$0.palabras.isEmpty }) else {
            return segmentos.map {
                (voz: Self.voz(de: $0.start, a: $0.end, en: utiles), segmento: $0)
            }
        }

        // Se aplana la pista entera antes de asignar. Hacerlo segmento por
        // segmento deja sin voz a la primera palabra de cada uno cuando cae en
        // un hueco entre turnos, porque no hay nada anterior de donde heredar.
        var palabras: [(palabra: Palabra, segmento: Int, voz: String?)] = []
        for (i, seg) in segmentos.enumerated() {
            for palabra in seg.palabras {
                palabras.append((
                    palabra: palabra,
                    segmento: i,
                    voz: Self.voz(de: palabra.start, a: palabra.end, en: utiles)
                        ?? Self.vozMasCercana(a: palabra.start, en: utiles)
                ))
            }
        }
        Self.suavizar(&palabras)

        // Se corta donde cambia la voz y tambien donde cambiaba el segmento
        // original, para no pegar frases que el motor habia separado por un
        // silencio.
        var salida: [(voz: String?, segmento: TranscriptSegment)] = []
        var actual: [Palabra] = []
        var vozActual: String?
        var segActual = -1

        func cerrar() {
            guard let primera = actual.first, let ultima = actual.last else { return }
            salida.append((
                voz: vozActual,
                segmento: TranscriptSegment(
                    start: primera.start,
                    end: ultima.end,
                    text: actual.map(\.texto).joined(separator: " "),
                    palabras: actual
                )
            ))
            actual = []
        }

        for p in palabras {
            if !actual.isEmpty, p.voz != vozActual || p.segmento != segActual { cerrar() }
            vozActual = p.voz
            segActual = p.segmento
            actual.append(p.palabra)
        }
        cerrar()

        // Los segmentos sin palabras se resuelven por solape y se reinsertan en
        // su lugar por tiempo, para no perderlos.
        let sinPalabras = segmentos.filter { $0.palabras.isEmpty }.map {
            (voz: Self.voz(de: $0.start, a: $0.end, en: utiles), segmento: $0)
        }
        return (salida + sinPalabras).sorted { $0.segmento.start < $1.segmento.start }
    }

    /// Devuelve al hablante de al lado los tramos demasiado cortos para ser un
    /// turno. Solo cuando los dos vecinos coinciden: si son distintos, el tramo
    /// corto puede ser el unico testigo de un cambio real.
    private static func suavizar(
        _ palabras: inout [(palabra: Palabra, segmento: Int, voz: String?)]
    ) {
        var i = 0
        while i < palabras.count {
            var j = i
            while j + 1 < palabras.count, palabras[j + 1].voz == palabras[i].voz { j += 1 }

            let dura = palabras[j].palabra.end - palabras[i].palabra.start
            let antes = i > 0 ? palabras[i - 1].voz : nil
            let despues = j + 1 < palabras.count ? palabras[j + 1].voz : nil

            if dura < turnoMinimo, let vecina = antes ?? despues,
               antes == nil || despues == nil || antes == despues {
                for k in i...j { palabras[k].voz = vecina }
            }
            i = j + 1
        }
    }

    /// La voz que mas cubre un tramo, o nil si ninguna lo toca.
    private static func voz(de inicio: Double, a fin: Double, en turnos: [Turno]) -> String? {
        var solape: [String: Double] = [:]
        for t in turnos {
            let cuanto = min(fin, t.fin) - max(inicio, t.inicio)
            if cuanto > 0 { solape[t.voz, default: 0] += cuanto }
        }
        return solape.max { $0.value < $1.value }?.key
    }

    /// La voz del turno mas cercano en el tiempo. Una palabra puede caer en un
    /// hueco entre turnos (el diarizador no marca cada instante) y dejarla sin
    /// voz la muestra como un interlocutor desconocido que no existe.
    private static func vozMasCercana(a instante: Double, en turnos: [Turno]) -> String? {
        turnos.min {
            Self.distancia(instante, $0) < Self.distancia(instante, $1)
        }?.voz
    }

    private static func distancia(_ instante: Double, _ t: Turno) -> Double {
        if instante < t.inicio { return t.inicio - instante }
        if instante > t.fin { return instante - t.fin }
        return 0
    }
}

/// Los turnos crudos de cada pista, en voces.json.
///
/// El transcript ya dice de que voz es cada frase; esto guarda el mapa completo
/// para que la capa del visor pueda ofrecer ponerle nombre a cada voz y ver
/// cuanto hablo cada una antes de decidir.
struct MapaDeVoces: Codable {
    let pistas: [String: [Voces.Turno]]

    /// La huella de cada voz, por pista. Es opcional porque los voces.json
    /// escritos antes de que esto existiera no la traen, y una grabacion vieja
    /// tiene que seguir abriendo igual.
    var huellas: [String: [String: [Float]]]?

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("voces.json"), options: .atomic)
    }
}
