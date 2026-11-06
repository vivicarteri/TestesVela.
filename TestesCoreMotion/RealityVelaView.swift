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
//  - A cera tem física de verdade (CeraSimulacao.swift, desenhada pelo CeraEntidades.swift):
//    • a chama derrete o topo e forma uma poça; a superfície da poça fica sempre reta em relação ao chão de verdade;
//    • quando a poça enche, transborda pelo ponto mais baixo da borda e os pingos escorrem pela vela,
//      esfriam e endurecem; por onde um pingo passa fica um canal, e os próximos tendem a sair por ali;
//    • inclinando o celular (para os lados, para frente ou para trás), a cera escorre e pinga para o lado
//      contrário da chama, cai no prato, na mesa ou na parede e vai acumulando em montinhos (com uma vibração leve);
//    • a chama e a vela são dois objetos: a chama sempre aponta para cima no mundo e derrete (destrói) a borda
//      em que encosta; se ela entra na cera ou o pavio afunda na poça (celular muito virado), ela é abafada e apaga.
//  - Para frente e para trás, conta como "em pé" o jeito que o celular estava quando a vela foi acesa
//    (assim dá para segurar o celular do jeito que for confortável).
//  - Virar o celular de cabeça para baixo também apaga, e inclinar faz derreter mais rápido.
//    (Usa o Movimento e o Haptics que estão no ContentView.)
//  - No simulador não tem sensor: arrastar a vela inclina o "celular" e dois toques endireitam.
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
    @State private var ultimoTick = Date()
    @State private var pregoCaiu = false
    @State private var ultimoPingo = Date.distantPast   // para não vibrar demais com muitas gotas juntas
    #if targetEnvironment(simulator)
    @State private var rolagemSimulada: Double = 0
    @State private var arfagemSimulada: Double = 0
    #endif

    // 30 vezes por segundo: anda a física da cera e atualiza a cena (chama tremendo, vela derretendo)
    private let relogio = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var progresso: Double { min(1, queimado / tamanho.duracao) }
    private var alturaEmMetros: Float { Float(tamanho.altura) / 1500 }   // pequena 13 cm, média 19 cm, grande 24 cm

    private var inclinado: Bool { movimento.inclinacao > 0.45 }

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                content.camera = .virtual          // 3D na tela, sem câmera do celular (sem AR)
                content.add(cena.raiz)
            }
            .ignoresSafeArea()
            #if targetEnvironment(simulator)
            // Simulador: arrastar para os lados inclina para os lados; para cima e para baixo, para trás e para frente
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    movimento.simular(rolagem: rolagemSimulada + v.translation.width / 90,
                                      arfagem: arfagemSimulada - v.translation.height / 90)
                }
                .onEnded { v in
                    rolagemSimulada += v.translation.width / 90
                    arfagemSimulada -= v.translation.height / 90
                })
            .onTapGesture(count: 2) {
                rolagemSimulada = 0
                arfagemSimulada = 0
                movimento.simular(rolagem: 0, arfagem: 0)
            }
            #endif
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

            #if targetEnvironment(simulator)
            Text("Simulador: arraste a vela para inclinar (lados, frente e trás). Dois toques endireitam.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            #endif
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
            cena.cera.reiniciar(alturaCheia: alturaEmMetros)
        }
        movimento.calibrar()
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
        cena.cera.reiniciar(alturaCheia: alturaEmMetros)
    }

    private func atualizar(_ data: Date) {
        defer { ultimoTick = data }

        // A física da cera e a cena andam sempre (a cera esfria e escorre mesmo com a vela apagada)
        cena.atualizar(agora: data,
                       progresso: Float(progresso),
                       acesa: estado == .acesa,
                       alturaCheia: alturaEmMetros,
                       gravidade: movimento.gravidadeNaCena)

        // Gotas de cera batendo no prato, na mesa ou na parede: uma batidinha leve
        if cena.cera.batidas > 0 {
            cena.cera.batidas = 0
            if data.timeIntervalSince(ultimoPingo) > 0.07 {
                ultimoPingo = data
                haptics.pingo()
            }
        }

        guard estado == .acesa else { return }

        // A chama encostou na cera (ou afundou na poça) tempo demais: ela apaga
        if cena.cera.apagouPorColisao {
            cena.cera.apagouPorColisao = false
            apagar()
            return
        }

        let passou = min(0.5, data.timeIntervalSince(ultimoTick))
        queimado += passou * (inclinado ? 2.5 : 1)
        haptics.atualizarChama(inclinacao: Float(min(1, movimento.inclinacao)))

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
    let cera: CeraSimulacao

    private let pavio: ModelEntity
    private let pivoChama = Entity()       // ponto de giro da chama (na ponta do pavio)
    private let prego = Entity()
    private let luzSombra = SpotLight()    // luz firme que faz as sombras na parede
    private let luzChama = PointLight()    // brilho quente em volta da chama
    private var brilho: Float = 0          // 0 = apagada, 1 = acesa (sobe e desce devagar)
    private var pregoCaindo = false

    private let desenhoCera: CeraEntidades  // a vela, a poça, os pingos e os montinhos (CeraEntidades.swift)

    private let alturaPrato: Float = 0.006
    private let raioVela: Float = 0.035

    init() {
        // Física da cera. Onde as gotas podem cair (o zero é a base da vela, em cima do prato):
        cera = CeraSimulacao()
        cera.superficies = [
            .init(ponto: [0, 0, 0], normal: [0, 1, 0], raio: 0.07),             // prato
            .init(ponto: [0, -alturaPrato, 0], normal: [0, 1, 0], raio: nil),   // mesa
            .init(ponto: [0, 0, -0.45], normal: [0, 0, 1], raio: nil)           // parede do fundo
        ]

        // Câmera: olhando a mesa de frente e de cima o bastante para ver a poça no topo da vela
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 40
        camera.look(at: [0, 0.05, -0.1], from: [0, 0.3, 0.6], relativeTo: nil)
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

        // Vela, poça, pingos e montinhos (o zero do desenho é a base da vela, em cima do prato)
        desenhoCera = CeraEntidades(cera: cera, corCera: UIColor(red: 0.96, green: 0.92, blue: 0.85, alpha: 1),
                                    rugosidade: 0.6)
        desenhoCera.raiz.position = [0, alturaPrato, 0]
        raiz.addChild(desenhoCera.raiz)

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
    func atualizar(agora: Date, progresso: Float, acesa: Bool, alturaCheia: Float, gravidade: SIMD3<Float>) {
        let t = Float(agora.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))

        // A chama acende e apaga devagar
        let alvo: Float = acesa ? 1 : 0
        brilho += (alvo - brilho) * 0.15

        // Vela derretendo: a altura (o timer) diminui e a física da cera faz o resto
        let alturaAtual = alturaCheia * max(0.06, 1 - progresso)
        cera.passo(.init(agora: agora, alturaCheia: alturaCheia, alturaPavio: alturaAtual,
                         brilho: brilho, acesa: acesa, gravidade: gravidade))
        desenhoCera.atualizar(brilho: brilho)

        // Pavio: sai do fundo da poça e vai até a ponta, onde fica a chama
        let pivo = cera.pivoDaChama(alturaPavio: alturaAtual) + SIMD3(0, alturaPrato, 0)
        let fundo = alturaPrato + cera.topo[0] - 0.001
        let comprimento = max(0.004, pivo.y - fundo)
        pavio.scale = [1, comprimento / 0.012, 1]
        pavio.position = [0, fundo + comprimento / 2, 0]

        // Chama: na ponta do pavio, SEMPRE para cima no mundo (mesmo com o celular virado), tremendo de leve.
        // Quando encosta na cera, vai sendo abafada e encolhe.
        let cima = cera.cima
        let n1 = ruido(t)
        let n2 = ruido(t * 1.7 + 10)
        pivoChama.position = pivo
        pivoChama.orientation = CeraEntidades.girar(de: [0, 1, 0], para: cima)
        let tamanhoChama = max(0.001, brilho * (1 - 0.6 * cera.abafamento))
        pivoChama.scale = [tamanhoChama * (1 - 0.05 * n2), tamanhoChama * (1 + 0.1 * n1), tamanhoChama]
        pivoChama.isEnabled = brilho > 0.02

        // Brilho em volta: treme só um pouquinho
        luzChama.position = pivo + cima * 0.018 + SIMD3(0, 0, 0.02)
        luzChama.light.intensity = 1500 * brilho * (1 + 0.04 * n1)

        // Luz das sombras: FIRME (não treme), sai da chama e aponta para a parede.
        // Como ela desce junto com a vela, as sombras sobem e crescem na parede.
        let origem = pivo + cima * 0.008
        luzSombra.look(at: [origem.x, origem.y, -0.45], from: origem, relativeTo: nil)
        luzSombra.light.intensity = 6000 * brilho

        // Prego espetado na metade da vela (até cair)
        if !pregoCaindo {
            prego.position = [raioVela + 0.004, alturaPrato + alturaCheia * 0.5, 0]
        }
    }

    // O prego cai no prato em 0,45 s (o mesmo tempo da batida no Prego.ahap)
    func derrubarPrego() {
        pregoCaindo = true
        prego.move(to: pregoNoPrato, relativeTo: raiz, duration: Haptics.tempoQueda, timingFunction: .easeIn)
    }

    // Onde o prego fica depois de cair
    private var pregoNoPrato: Transform {
        var destino = prego.transform
        destino.translation = [0.05, alturaPrato + 0.004, 0.03]
        destino.rotation = simd_quatf(angle: 0.8, axis: [0, 1, 0])
        return destino
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
