//  RealityVelaView.swift
//  Teste de RealityKit: a vela em 3D, com luz de verdade e sombras de verdade.
//
//  O que dá para testar:
//  - Uma mesa, uma parede, um prato, a vela, uma arvorezinha e uma casinha.
//  - A luz sai da chama. A arvorezinha e a casinha fazem SOMBRA de verdade na parede.
//  - Conforme a vela derrete, a chama desce e as sombras SOBEM e CRESCEM na parede.
//    (É o teatro de sombras marcando o tempo!)
//  - A luz que faz as sombras é firme (não treme), como a pesquisa sugeriu.
//    Só a chama e o brilho em volta dela tremem de leve.
//  - Prego: cai no prato na metade do tempo (com a vibração do Prego.ahap).
//  - Chama sempre para cima, virar o celular apaga, inclinar derrete mais rápido:
//    igual à versão 2D (usa o Movimento e o Haptics que já estão no ContentView).
//
//  Precisa de iOS 18 ou mais novo (RealityView com câmera virtual).

import SwiftUI
import Combine
import RealityKit

struct RealityVelaView: View {
    enum Estado { case apagada, acesa, pausada, fim }

    @StateObject private var movimento = Movimento()
    @State private var haptics = Haptics()
    @State private var cena = CenaVela()

    @State private var tamanho: TamanhoVela = .media
    @State private var estado: Estado = .apagada
    @State private var queimado: TimeInterval = 0
    @State private var agora = Date()
    @State private var ultimoTick = Date()
    @State private var pregoCaiu = false

    // 30 vezes por segundo: atualiza a cena (chama tremendo, vela derretendo)
    private let relogio = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var progresso: Double { min(1, queimado / tamanho.duracao) }
    private var inclinado: Bool { abs(movimento.angulo) > 0.45 }
    private var alturaEmMetros: Float { Float(tamanho.altura) / 1500 }   // pequena 13 cm, média 19 cm, grande 24 cm

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                content.camera = .virtual          // 3D na tela, sem câmera do celular (sem AR)
                content.add(cena.raiz)
            } update: { _ in
                cena.atualizar(agora: agora,
                               progresso: Float(progresso),
                               acesa: estado == .acesa,
                               alturaCheia: alturaEmMetros,
                               angulo: Float(movimento.angulo))
            }
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("Vela \(tamanho.rawValue.lowercased())")
            .accessibilityValue(textoEstado)

            controles
        }
        .background(Color.black)
        .onAppear { movimento.iniciar() }
        .onDisappear { movimento.parar(); haptics.pararChama() }
        .onReceive(relogio) { data in atualizar(data) }
        .onChange(of: movimento.invertido) { _, invertido in
            if invertido { apagar() }
        }
        .onChange(of: tamanho) { _, _ in
            haptics.tique()
            if estado == .fim { recomecar() }
        }
    }

    // MARK: Controles

    private var controles: some View {
        VStack(spacing: 12) {
            Text(textoEstado)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))

            if estado == .apagada || estado == .fim {
                Picker("Tamanho", selection: $tamanho) {
                    ForEach(TamanhoVela.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                if estado != .acesa {
                    Button("Acender") { acender() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                if estado == .acesa || estado == .pausada {
                    Button("Recomeçar") { recomecar() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var textoEstado: String {
        switch estado {
        case .apagada: return "Vela apagada"
        case .pausada: return "Vela pausada"
        case .fim:     return "A vela acabou"
        case .acesa:
            switch progresso {
            case ..<0.25: return "Vela acesa, quase inteira"
            case ..<0.5:  return "Vela acesa, chegando na metade"
            case ..<0.75: return "Vela acesa, passou da metade"
            default:      return "Vela acesa, quase no fim"
            }
        }
    }

    // MARK: Ações

    private func acender() {
        if estado == .fim {
            queimado = 0
            pregoCaiu = false
            cena.recolocarPrego()
        }
        estado = .acesa
        ultimoTick = Date()
        haptics.acender()
        haptics.iniciarChama()
    }

    private func apagar() {
        guard estado == .acesa else { return }
        estado = .pausada
        haptics.pararChama()
        haptics.apagar()
    }

    private func recomecar() {
        if estado == .acesa { haptics.apagar() }
        haptics.pararChama()
        estado = .apagada
        queimado = 0
        pregoCaiu = false
        cena.recolocarPrego()
    }

    private func atualizar(_ data: Date) {
        agora = data   // faz o RealityView atualizar a cena
        defer { ultimoTick = data }
        guard estado == .acesa else { return }

        let passou = min(0.5, data.timeIntervalSince(ultimoTick))
        queimado += passou * (inclinado ? 2.5 : 1)
        haptics.atualizarChama(inclinacao: Float(min(1, abs(movimento.angulo))))

        if progresso >= 0.5 && !pregoCaiu {
            pregoCaiu = true
            cena.derrubarPrego()
            haptics.prego(forca: Float(tamanho.altura / TamanhoVela.grande.altura))
        }

        if progresso >= 1 {
            estado = .fim
            haptics.pararChama()
            haptics.fim()
        }
    }
}

// MARK: - A cena 3D

@MainActor
final class CenaVela {
    let raiz = Entity()

    private let vela: ModelEntity
    private let pavio: ModelEntity
    private let pivoChama = Entity()   // ponto de giro da chama (na ponta do pavio)
    private let prego = Entity()
    private let luzSombra = SpotLight() // luz firme que faz as sombras na parede
    private let luzChama = PointLight() // brilho quente em volta da chama
    private var brilho: Float = 0       // 0 = apagada, 1 = acesa (sobe e desce devagar)
    private var pregoCaindo = false

    private let alturaPrato: Float = 0.006
    private let raioVela: Float = 0.035

    init() {
        // Câmera: olhando a mesa de frente, um pouco de cima
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 40
        camera.look(at: [0, 0.12, -0.15], from: [0, 0.2, 0.7], relativeTo: nil)
        raiz.addChild(camera)

        // Mesa
        let mesa = ModelEntity(mesh: .generatePlane(width: 2, depth: 2),
                               materials: [SimpleMaterial(color: UIColor(red: 0.30, green: 0.20, blue: 0.14, alpha: 1),
                                                          roughness: 0.8, isMetallic: false)])
        raiz.addChild(mesa)

        // Parede (é nela que as sombras aparecem)
        let parede = ModelEntity(mesh: .generatePlane(width: 2, height: 1.2),
                                 materials: [SimpleMaterial(color: UIColor(red: 0.85, green: 0.80, blue: 0.72, alpha: 1),
                                                            roughness: 0.95, isMetallic: false)])
        parede.position = [0, 0.6, -0.45]
        raiz.addChild(parede)

        // Prato de metal
        let prato = ModelEntity(mesh: .generateCylinder(height: alturaPrato, radius: 0.07),
                                materials: [SimpleMaterial(color: .gray, roughness: 0.3, isMetallic: true)])
        prato.position = [0, alturaPrato / 2, 0]
        raiz.addChild(prato)

        // Vela: um cilindro de altura 1 que a gente "achata" (escala) conforme derrete
        vela = ModelEntity(mesh: .generateCylinder(height: 1, radius: raioVela),
                           materials: [SimpleMaterial(color: UIColor(red: 0.96, green: 0.92, blue: 0.85, alpha: 1),
                                                      roughness: 0.6, isMetallic: false)])
        raiz.addChild(vela)

        // Pavio
        pavio = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.0012),
                            materials: [SimpleMaterial(color: .black, isMetallic: false)])
        raiz.addChild(pavio)

        // Chama: uma esfera esticada e meio transparente, com um miolo claro dentro
        var corChama = UnlitMaterial(color: UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
        corChama.blending = .transparent(opacity: 0.85)
        let chama = ModelEntity(mesh: .generateSphere(radius: 0.007), materials: [corChama])
        chama.position = [0, 0.012, 0]
        chama.scale = [1, 2.4, 1]
        pivoChama.addChild(chama)

        let miolo = ModelEntity(mesh: .generateSphere(radius: 0.004),
                                materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 1))])
        miolo.position = [0, 0.009, 0]
        miolo.scale = [1, 1.8, 1]
        pivoChama.addChild(miolo)
        raiz.addChild(pivoChama)

        // Objetos que fazem sombra: arvorezinha e casinha, entre a vela e a parede
        let madeira = SimpleMaterial(color: UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 1), isMetallic: false)
        let folhas = SimpleMaterial(color: UIColor(red: 0.18, green: 0.32, blue: 0.18, alpha: 1), isMetallic: false)
        let tronco = ModelEntity(mesh: .generateCylinder(height: 0.05, radius: 0.006), materials: [madeira])
        tronco.position = [-0.1, 0.025, -0.2]
        let copa = ModelEntity(mesh: .generateCone(height: 0.12, radius: 0.035), materials: [folhas])
        copa.position = [-0.1, 0.11, -0.2]
        raiz.addChild(tronco)
        raiz.addChild(copa)

        let tijolo = SimpleMaterial(color: UIColor(red: 0.55, green: 0.35, blue: 0.28, alpha: 1), isMetallic: false)
        let casa = ModelEntity(mesh: .generateBox(size: 0.05), materials: [tijolo])
        casa.position = [0.11, 0.025, -0.22]
        let telhado = ModelEntity(mesh: .generateBox(size: 0.036), materials: [madeira])
        telhado.position = [0.11, 0.05, -0.22]
        telhado.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
        raiz.addChild(casa)
        raiz.addChild(telhado)

        // Prego: haste + cabeça
        let metal = SimpleMaterial(color: .lightGray, roughness: 0.25, isMetallic: true)
        let haste = ModelEntity(mesh: .generateCylinder(height: 0.016, radius: 0.0012), materials: [metal])
        haste.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let cabeca = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.0035), materials: [metal])
        cabeca.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        cabeca.position = [0.008, 0, 0]
        prego.addChild(haste)
        prego.addChild(cabeca)
        raiz.addChild(prego)

        // Luz que faz as sombras: sai da chama e aponta para a parede
        luzSombra.light.color = UIColor(red: 1, green: 0.72, blue: 0.45, alpha: 1)
        luzSombra.light.innerAngleInDegrees = 60
        luzSombra.light.outerAngleInDegrees = 120
        luzSombra.light.attenuationRadius = 3
        luzSombra.light.intensity = 0
        luzSombra.shadow = SpotLightComponent.Shadow()
        raiz.addChild(luzSombra)

        // Brilho quente em volta da chama (ilumina a cera e a mesa)
        luzChama.light.color = UIColor(red: 1, green: 0.6, blue: 0.3, alpha: 1)
        luzChama.light.attenuationRadius = 0.8
        luzChama.light.intensity = 0
        raiz.addChild(luzChama)

        // Uma luz bem fraquinha, só para a cena não ficar 100% preta com a vela apagada
        let luzQuarto = PointLight()
        luzQuarto.light.intensity = 150
        luzQuarto.light.attenuationRadius = 3
        luzQuarto.position = [0, 0.6, 0.6]
        raiz.addChild(luzQuarto)
    }

    // Chamado 30 vezes por segundo
    func atualizar(agora: Date, progresso: Float, acesa: Bool, alturaCheia: Float, angulo: Float) {
        let t = Float(agora.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))

        // A chama acende e apaga devagar
        let alvo: Float = acesa ? 1 : 0
        brilho += (alvo - brilho) * 0.15

        // Vela derretendo: a altura diminui e tudo que está em cima desce junto
        let alturaAtual = alturaCheia * max(0.06, 1 - progresso)
        vela.scale = [1, alturaAtual, 1]
        vela.position = [0, alturaPrato + alturaAtual / 2, 0]
        let topo = alturaPrato + alturaAtual
        pavio.position = [0, topo + 0.006, 0]

        // Chama: na ponta do pavio, sempre para cima, tremendo de leve
        let n1 = ruido(t)
        let n2 = ruido(t * 1.7 + 10)
        pivoChama.position = [0, topo + 0.012, 0]
        pivoChama.orientation = simd_quatf(angle: -max(-1, min(1, angulo)), axis: [0, 0, 1])
        let tamanhoChama = max(0.001, brilho)
        pivoChama.scale = [tamanhoChama * (1 - 0.05 * n2), tamanhoChama * (1 + 0.1 * n1), tamanhoChama]
        pivoChama.isEnabled = brilho > 0.02

        // Brilho em volta: treme só um pouquinho
        luzChama.position = [0, topo + 0.03, 0.02]
        luzChama.light.intensity = 1500 * brilho * (1 + 0.04 * n1)

        // Luz das sombras: FIRME (não treme), sai da chama e aponta para a parede.
        // Como ela desce junto com a vela, as sombras sobem e crescem na parede.
        let origem: SIMD3<Float> = [0, topo + 0.02, 0]
        luzSombra.look(at: [0, topo + 0.02, -0.45], from: origem, relativeTo: nil)
        luzSombra.light.intensity = 6000 * brilho

        // Prego espetado na metade da vela (até cair)
        if !pregoCaindo {
            prego.position = [raioVela + 0.004, alturaPrato + alturaCheia * 0.5, 0]
        }
    }

    // O prego cai no prato em 0,45 s (o mesmo tempo da batida no Prego.ahap)
    func derrubarPrego() {
        pregoCaindo = true
        var destino = prego.transform
        destino.translation = [0.05, alturaPrato + 0.004, 0.03]
        destino.rotation = simd_quatf(angle: 0.8, axis: [0, 1, 0])
        prego.move(to: destino, relativeTo: raiz, duration: Haptics.tempoQueda, timingFunction: .easeIn)
    }

    func recolocarPrego() {
        pregoCaindo = false
        prego.stopAllAnimations()
        prego.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }

    private func ruido(_ t: Float) -> Float {
        sin(t * 7.3) * 0.5 + sin(t * 13.1 + 1.3) * 0.3 + sin(t * 23.7 + 2.1) * 0.2
    }
}

#Preview {
    RealityVelaView()
}
