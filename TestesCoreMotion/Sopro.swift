//  Sopro.swift
//  Apagar a vela soprando no microfone, e comparar qual microfone do iPhone funciona melhor.
//
//  Os microfones do iPhone (o iOS chama cada um de "data source" do microfone embutido):
//  - Inferior: embaixo, do lado do conector.
//  - Frontal: em cima, do lado da tela (perto do alto-falante de ligação).
//  - Traseiro: em cima, atrás, perto da câmera.
//  O iOS só entrega UM microfone por vez, ou DOIS juntos no modo estéreo. Por isso o modo
//  "Superior + inferior" usa o estéreo virado na direção do comprimento do celular: um canal
//  ouve mais a parte de cima e o outro a de baixo. Comparando os dois dá para estimar a ALTURA
//  em que o sopro bateu no celular, e dá para comparar com a altura em que a chama está na tela.
//
//  Como sabemos que é um sopro (e não uma voz ou uma palma):
//  - o som tem que passar do limite (a "sensibilidade" muda esse limite);
//  - a maior parte do som tem que ser grave (vento batendo no microfone é um ronco grave);
//  - e tem que durar um pouquinho (0,15 s), porque uma palma é muito rápida.
//
//  Cada sopro fica guardado em "Resultados": que microfone, a força em cada canal, a altura
//  estimada do sopro, a altura da chama na tela e se a vela apagou. Dá para compartilhar a lista.
//
//  O modo do áudio é o .measurement: o iOS não mexe no volume nem tira o barulho do vento
//  (nos outros modos ele "limpa" o vento, que é justamente o sopro).

import SwiftUI
import Combine
import AVFoundation

// MARK: - Qual microfone

enum MicrofoneSopro: String, CaseIterable, Identifiable {
    case superiorEInferior, inferior, frontal, traseiro, padrao

    var id: String { rawValue }

    var nome: String {
        switch self {
        case .superiorEInferior: return "Superior + inferior (juntos)"
        case .inferior:          return "Inferior (embaixo)"
        case .frontal:           return "Frontal (em cima, na tela)"
        case .traseiro:          return "Traseiro (perto da câmera)"
        case .padrao:            return "Microfone padrão"
        }
    }

    var nomeCurto: String {
        switch self {
        case .superiorEInferior: return "Superior + inferior"
        case .inferior:          return "Inferior"
        case .frontal:           return "Frontal"
        case .traseiro:          return "Traseiro"
        case .padrao:            return "Padrão"
        }
    }
}

/// O nível de um canal do microfone, em dB (0 = o máximo; -60 = quase silêncio)
struct CanalSopro: Identifiable, Hashable {
    let nome: String
    let db: Float
    var id: String { nome }
}

/// Um sopro que acabou de ser ouvido
struct LeituraSopro {
    let microfone: MicrofoneSopro
    let canais: [CanalSopro]       // o mais forte que cada canal chegou durante o sopro
    let alturaSopro: Double?       // 0 = embaixo do celular, 1 = em cima (só com os dois juntos)
}

/// Um sopro guardado para comparar os microfones depois
struct ResultadoSopro: Identifiable {
    let id = UUID()
    let data: Date
    let aba: String
    let leitura: LeituraSopro
    let alturaChama: Double        // onde a chama estava na tela: 0 = embaixo, 1 = em cima
    let alturaVela: Double         // quanto da vela ainda tinha: 1 = inteira
    let apagou: Bool

    var maisForte: CanalSopro? { leitura.canais.max { $0.db < $1.db } }

    /// Diferença entre a altura estimada do sopro e a altura da chama (0 = acertou em cheio)
    var erroAltura: Double? { leitura.alturaSopro.map { abs($0 - alturaChama) } }
}

// MARK: - O detector (um só para o app todo, as três abas usam o mesmo)

@MainActor
final class Sopro: ObservableObject {
    static let compartilhado = Sopro()

    @Published private(set) var ligado = false
    @Published private(set) var microfone: MicrofoneSopro
    @Published private(set) var disponiveis: [MicrofoneSopro] = [.padrao]
    @Published private(set) var niveis: [CanalSopro] = []       // ao vivo
    @Published private(set) var soprando = false
    @Published private(set) var aviso: String?
    @Published private(set) var resultados: [ResultadoSopro] = []

    /// 0 = só um sopro bem forte apaga; 1 = qualquer soprinho apaga
    @Published var sensibilidade: Double {
        didSet { UserDefaults.standard.set(sensibilidade, forKey: "sopro.sensibilidade") }
    }

    /// A partir de quantos dB conta como sopro (muda com a sensibilidade)
    var limiar: Float { -12 - 33 * Float(sensibilidade) }

    /// Avisa as abas que alguém soprou (só a aba que está na tela apaga a vela)
    let soprou = PassthroughSubject<LeituraSopro, Never>()

    private var motor: AVAudioEngine?
    private var nomesDosCanais: [String] = []
    private var tempoSoprando: Double = 0
    private var tempoQuieto: Double = 0
    private var picos: [Float] = []
    private var energias: [Double] = []
    private var esperarAte = Date.distantPast
    private var reiniciando = false
    private var observador: NSObjectProtocol?

    private init() {
        let salvo = UserDefaults.standard.string(forKey: "sopro.microfone")
        microfone = salvo.flatMap(MicrofoneSopro.init(rawValue:)) ?? .superiorEInferior
        let sensibilidadeSalva = UserDefaults.standard.object(forKey: "sopro.sensibilidade") as? Double
        sensibilidade = sensibilidadeSalva ?? 0.5
    }

    // MARK: Ligar e desligar

    func ligar(_ ligar: Bool) {
        guard ligar != ligado else { return }
        if !ligar {
            parar()
            ligado = false
            niveis = []
            soprando = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.ambient)   // volta a ser como antes
            #endif
            return
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            comecarAOuvir()
        case .denied:
            aviso = "Sem permissão para o microfone. Ligue em Ajustes > Privacidade > Microfone."
        default:
            // Primeira vez: o iOS pergunta para a pessoa
            AVAudioApplication.requestRecordPermission { @Sendable permitiu in
                Task { @MainActor in
                    let sopro = Sopro.compartilhado
                    if permitiu {
                        sopro.comecarAOuvir()
                    } else {
                        sopro.aviso = "Sem permissão para o microfone. Ligue em Ajustes > Privacidade > Microfone."
                    }
                }
            }
        }
    }

    private func comecarAOuvir() {
        ligado = true
        iniciar()
    }

    func escolher(_ novo: MicrofoneSopro) {
        guard novo != microfone else { return }
        microfone = novo
        UserDefaults.standard.set(novo.rawValue, forKey: "sopro.microfone")
        if ligado { iniciar() }
    }

    /// A aba que apagou (ou não) a vela guarda o resultado
    func registrar(_ leitura: LeituraSopro, aba: String, alturaChama: Double, alturaVela: Double, apagou: Bool) {
        resultados.append(ResultadoSopro(data: Date(), aba: aba, leitura: leitura,
                                         alturaChama: max(0, min(1, alturaChama)),
                                         alturaVela: max(0, min(1, alturaVela)), apagou: apagou))
        if resultados.count > 300 { resultados.removeFirst(resultados.count - 300) }
    }

    func limparResultados() { resultados = [] }

    private func parar() {
        motor?.inputNode.removeTap(onBus: 0)
        motor?.stop()
        motor = nil
        if let observador { NotificationCenter.default.removeObserver(observador) }
        observador = nil
    }

    private func iniciar() {
        parar()
        aviso = nil
        tempoSoprando = 0
        do {
            let canaisPedidos = try configurarSessao()

            let motor = AVAudioEngine()
            let entrada = motor.inputNode
            let formato = entrada.outputFormat(forBus: 0)
            guard formato.sampleRate > 0, formato.channelCount > 0 else {
                aviso = "O microfone não respondeu."
                return
            }
            let canais = Int(formato.channelCount)
            nomesDosCanais = nomes(canais: canais)
            if canaisPedidos == 2 && canais < 2 {
                aviso = "Este iPhone não entregou os dois microfones juntos: só um canal."
            }

            let analisador = AnalisadorSopro(taxa: formato.sampleRate)
            entrada.installTap(onBus: 0, bufferSize: 1024, format: formato,
                               block: analisador.blocoDoTap { [weak self] medida in
                Task { @MainActor in self?.receber(medida) }
            })
            try motor.start()
            self.motor = motor
            print("[Sopro] ouvindo: \(microfone.nomeCurto), \(canais) canal(is), \(Int(formato.sampleRate)) Hz")

            // Se o áudio mudar (fone, ligação, outra tela mexendo no áudio), liga de novo
            observador = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: motor, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reiniciarDepois() }
            }
        } catch {
            print("[Sopro] erro: \(error)")
            aviso = "Não deu para usar o microfone \(microfone.nomeCurto.lowercased()): \(error.localizedDescription)"
        }
    }

    private func reiniciarDepois() {
        guard ligado, !reiniciando else { return }
        reiniciando = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reiniciando = false
            if ligado { iniciar() }
        }
    }

    private func nomes(canais: Int) -> [String] {
        if canais >= 2 && microfone == .superiorEInferior {
            // Estéreo deitado com o conector à direita: o canal da esquerda é o alto do celular
            return ["Superior", "Inferior"] + (2..<canais).map { "Canal \($0 + 1)" }
        }
        if canais == 1 { return [microfone.nomeCurto] }
        return (0..<canais).map { "Canal \($0 + 1)" }
    }

    // MARK: Sessão de áudio: escolhe o microfone

    /// Devolve quantos canais pediu (1 ou 2)
    private func configurarSessao() throws -> Int {
        #if os(iOS)
        let sessao = AVAudioSession.sharedInstance()
        try sessao.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try sessao.setAllowHapticsAndSystemSoundsDuringRecording(true)   // sem isso a vibração para
        try sessao.setActive(true)

        guard let embutido = sessao.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            disponiveis = [.padrao]
            if microfone != .padrao { microfone = .padrao }
            return 1
        }
        try sessao.setPreferredInput(embutido)

        let fontes = embutido.dataSources ?? []
        func fonte(_ lado: AVAudioSession.Orientation) -> AVAudioSessionDataSourceDescription? {
            fontes.first { $0.orientation == lado }
        }
        let estereo = [fonte(.front), fonte(.bottom), fonte(.back)].compactMap { $0 }
            .first { $0.supportedPolarPatterns?.contains(.stereo) == true }

        var lista: [MicrofoneSopro] = []
        if estereo != nil { lista.append(.superiorEInferior) }
        if fonte(.bottom) != nil { lista.append(.inferior) }
        if fonte(.front) != nil { lista.append(.frontal) }
        if fonte(.back) != nil { lista.append(.traseiro) }
        if lista.isEmpty { lista = [.padrao] }   // simulador: só o microfone do Mac
        disponiveis = lista
        if !lista.contains(microfone) { microfone = lista[0] }

        switch microfone {
        case .superiorEInferior:
            guard let estereo else { return 1 }
            try estereo.setPreferredPolarPattern(.stereo)
            try embutido.setPreferredDataSource(estereo)
            try sessao.setPreferredInputOrientation(.landscapeLeft)   // o estéreo no comprimento do celular
            if sessao.maximumInputNumberOfChannels >= 2 { try sessao.setPreferredInputNumberOfChannels(2) }
            return 2
        case .inferior, .frontal, .traseiro:
            let lado: AVAudioSession.Orientation = microfone == .inferior ? .bottom : microfone == .frontal ? .front : .back
            guard let escolhida = fonte(lado) else { return 1 }
            if escolhida.supportedPolarPatterns?.contains(.omnidirectional) == true {
                try escolhida.setPreferredPolarPattern(.omnidirectional)
            }
            try embutido.setPreferredDataSource(escolhida)
            try sessao.setPreferredInputNumberOfChannels(1)
            return 1
        case .padrao:
            return 1
        }
        #else
        disponiveis = [.padrao]
        microfone = .padrao
        return 1
        #endif
    }

    // MARK: Decidir se é sopro (chamado umas 40 vezes por segundo)

    private func receber(_ medida: MedidaSopro) {
        guard ligado else { return }
        niveis = zip(nomesDosCanais, medida.db).map { CanalSopro(nome: $0, db: $1) }

        let limite = limiar
        let algumSoprando = zip(medida.db, medida.graves).contains { db, graves in db > limite && graves > 0.45 }
        if algumSoprando {
            tempoQuieto = 0
            tempoSoprando += medida.duracao
            if picos.count != medida.db.count {
                picos = medida.db
                energias = Array(repeating: 0, count: medida.db.count)
            }
            for i in medida.db.indices {
                picos[i] = max(picos[i], medida.db[i])
                energias[i] += pow(10, Double(medida.db[i]) / 10) * medida.duracao
            }
        } else {
            tempoQuieto += medida.duracao
            if tempoQuieto > 0.08 {       // parou de soprar
                tempoSoprando = 0
                picos = []
                energias = []
            }
        }
        soprando = tempoSoprando > 0

        let agora = Date()
        guard tempoSoprando >= 0.15, agora >= esperarAte else { return }
        esperarAte = agora.addingTimeInterval(1.2)   // um sopro só conta uma vez

        var altura: Double?
        if microfone == .superiorEInferior && energias.count >= 2 && energias[0] + energias[1] > 0 {
            altura = energias[0] / (energias[0] + energias[1])
        }
        let leitura = LeituraSopro(microfone: microfone,
                                   canais: zip(nomesDosCanais, picos).map { CanalSopro(nome: $0, db: $1) },
                                   alturaSopro: altura)
        tempoSoprando = 0
        picos = []
        energias = []
        soprou.send(leitura)
    }
}

// MARK: - A conta do som (roda na linha de áudio, fora da tela)

nonisolated struct MedidaSopro: Sendable {
    let db: [Float]        // o volume de cada canal
    let graves: [Float]    // quanto do som é grave (0 a 1): sopro é quase todo grave
    let duracao: Double    // quantos segundos de som vieram
}

nonisolated final class AnalisadorSopro: @unchecked Sendable {
    private let taxa: Double
    private let a: Float               // filtro que deixa passar só os graves (até uns 300 Hz)
    private var filtro: [Float] = []   // um por canal

    init(taxa: Double) {
        self.taxa = taxa
        a = Float(exp(-2 * Double.pi * 300 / taxa))
    }

    func blocoDoTap(_ entregar: @escaping @Sendable (MedidaSopro) -> Void) -> AVAudioNodeTapBlock {
        return { [self] buffer, _ in
            guard let dados = buffer.floatChannelData else { return }
            let canais = Int(buffer.format.channelCount)
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            if filtro.count != canais { filtro = Array(repeating: 0, count: canais) }

            var db: [Float] = []
            var graves: [Float] = []
            for c in 0..<canais {
                let x = dados[c]
                var lp = filtro[c]
                var total: Float = 0
                var grave: Float = 0
                for i in 0..<n {
                    let s = x[i]
                    lp = (1 - a) * s + a * lp
                    total += s * s
                    grave += lp * lp
                }
                filtro[c] = lp
                let rms = (total / Float(n)).squareRoot()
                let rmsGrave = (grave / Float(n)).squareRoot()
                db.append(20 * log10(max(rms, 0.000_001)))
                graves.append(rms > 0 ? min(1, rmsGrave / rms) : 0)
            }
            entregar(MedidaSopro(db: db, graves: graves, duracao: Double(n) / taxa))
        }
    }
}

// MARK: - O painel do microfone (vai embaixo, junto com os botões de cada aba)

struct PainelSopro: View {
    @ObservedObject private var sopro = Sopro.compartilhado
    @State private var mostrarResultados = false

    var body: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(get: { sopro.ligado }, set: { sopro.ligar($0) })) {
                Label("Apagar soprando", systemImage: "wind")
            }
            .tint(.orange)

            if sopro.ligado {
                HStack {
                    Menu {
                        Picker("Microfone", selection: Binding(get: { sopro.microfone }, set: { sopro.escolher($0) })) {
                            ForEach(sopro.disponiveis) { Text($0.nome).tag($0) }
                        }
                    } label: {
                        Label(sopro.microfone.nomeCurto, systemImage: "mic")
                            .font(.footnote.weight(.semibold))
                    }
                    .tint(.white)
                    .accessibilityLabel("Microfone: \(sopro.microfone.nome)")

                    Spacer()

                    Button("Resultados (\(sopro.resultados.count))") { mostrarResultados = true }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }

                ForEach(sopro.niveis) { canal in
                    MedidorSopro(canal: canal, limiar: sopro.limiar, soprando: sopro.soprando)
                }

                HStack {
                    Text("Sensibilidade")
                    Slider(value: $sopro.sensibilidade)
                        .tint(.orange)
                        .accessibilityValue("\(Int(sopro.sensibilidade * 100)) por cento")
                }

                if let ultimo = sopro.resultados.last {
                    Text(ultimo.resumo)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }

            if let aviso = sopro.aviso {
                Text(aviso)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .sheet(isPresented: $mostrarResultados) {
            ResultadosSoproView()
                .presentationDetents([.medium, .large])
        }
    }
}

/// Uma barrinha com o volume do canal. A risca amarela é o limite: passou dela (e é grave), é sopro.
struct MedidorSopro: View {
    let canal: CanalSopro
    let limiar: Float
    let soprando: Bool

    private func posicao(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }

    var body: some View {
        HStack(spacing: 8) {
            Text(canal.nome)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(canal.db > limiar && soprando ? Color.orange : Color.white.opacity(0.7))
                        .frame(width: geo.size.width * posicao(canal.db))
                    Rectangle()
                        .fill(.yellow)
                        .frame(width: 2)
                        .offset(x: geo.size.width * posicao(limiar) - 1)
                }
            }
            .frame(height: 8)
            Text("\(Int(canal.db.rounded())) dB")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microfone \(canal.nome)")
        .accessibilityValue("\(Int(canal.db.rounded())) decibéis")
    }
}

// MARK: - Resultados: para ver qual microfone foi melhor

struct ResultadosSoproView: View {
    @ObservedObject private var sopro = Sopro.compartilhado
    @Environment(\.dismiss) private var fechar

    var body: some View {
        NavigationStack {
            List {
                if sopro.resultados.isEmpty {
                    Text("Ligue \"Apagar soprando\", acenda a vela e sopre. Cada sopro aparece aqui.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Por microfone") {
                        ForEach(MicrofoneSopro.allCases) { mic in
                            let deste = sopro.resultados.filter { $0.leitura.microfone == mic }
                            if !deste.isEmpty { LinhaResumoMicrofone(microfone: mic, resultados: deste) }
                        }
                    }
                    Section("Cada sopro (o mais novo em cima)") {
                        ForEach(sopro.resultados.reversed()) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(r.aba) · \(r.leitura.microfone.nomeCurto) · \(r.apagou ? "apagou" : "vela não estava acesa")")
                                    .font(.subheadline.weight(.semibold))
                                Text(r.leitura.canais.map { "\($0.nome) \(Int($0.db.rounded())) dB" }.joined(separator: " · "))
                                Text(r.textoAlturas)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Resultados do sopro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Limpar", role: .destructive) { sopro.limparResultados() }
                        .disabled(sopro.resultados.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: textoParaCompartilhar) { Image(systemName: "square.and.arrow.up") }
                        .disabled(sopro.resultados.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { fechar() }
                }
            }
        }
    }

    // Uma linha por sopro, separada por ";" (abre direto no Numbers ou no Excel)
    private var textoParaCompartilhar: String {
        var linhas = ["hora;aba;microfone;canais (dB);altura do sopro;altura da chama;vela restante;apagou"]
        let hora = Date.FormatStyle(date: .omitted, time: .standard)
        for r in sopro.resultados {
            let canais = r.leitura.canais.map { "\($0.nome) \(Int($0.db.rounded()))" }.joined(separator: " / ")
            let alturaSopro = r.leitura.alturaSopro.map { "\(Int($0 * 100))%" } ?? "-"
            linhas.append("\(r.data.formatted(hora));\(r.aba);\(r.leitura.microfone.nomeCurto);\(canais);\(alturaSopro);"
                          + "\(Int(r.alturaChama * 100))%;\(Int(r.alturaVela * 100))%;\(r.apagou ? "sim" : "não")")
        }
        return linhas.joined(separator: "\n")
    }
}

struct LinhaResumoMicrofone: View {
    let microfone: MicrofoneSopro
    let resultados: [ResultadoSopro]

    var body: some View {
        let forca = resultados.compactMap { $0.maisForte?.db }
        let media = forca.isEmpty ? 0 : forca.reduce(0, +) / Float(forca.count)
        let erros = resultados.compactMap(\.erroAltura)
        VStack(alignment: .leading, spacing: 2) {
            Text(microfone.nome).font(.subheadline.weight(.semibold))
            Text("\(resultados.count) sopro\(resultados.count == 1 ? "" : "s") · força média \(Int(media.rounded())) dB")
            if !erros.isEmpty {
                let erroMedio = erros.reduce(0, +) / Double(erros.count)
                Text("Altura do sopro x altura da chama: erra em média \(Int((erroMedio * 100).rounded())) pontos")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

extension ResultadoSopro {
    var textoAlturas: String {
        let chama = "chama a \(Int(alturaChama * 100))% da tela, vela com \(Int(alturaVela * 100))%"
        guard let s = leitura.alturaSopro else { return chama }
        return "sopro a \(Int(s * 100))% da altura do celular · " + chama
    }

    /// A linha curtinha que aparece no painel
    var resumo: String {
        let forte = maisForte.map { "mais forte: \($0.nome) \(Int($0.db.rounded())) dB" } ?? ""
        let altura = leitura.alturaSopro.map { " · sopro a \(Int($0 * 100))%, chama a \(Int(alturaChama * 100))%" } ?? ""
        return "Último sopro (\(leitura.microfone.nomeCurto)): \(forte)\(altura)"
    }
}
