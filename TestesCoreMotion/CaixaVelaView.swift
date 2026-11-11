//  CaixaVelaView.swift
//  Teste "Out of the box": a vela dentro de uma caixa que gira, com o timer completo.
//
//  O que dá para testar:
//  - Caixa de madeira com PADRÕES recortados (estrelas, luas, corações, círculos),
//    um padrão diferente em cada lado. No meio de cada lado tem uma "janela" grande.
//  - A caixa GIRA bem devagar (uma volta a cada 90 segundos), como um carrossel de sombras:
//    as formas de luz andam devagar pelas paredes do quarto.
//  - Timer igual às outras telas: escolher o tamanho, acender, a vela derrete com o tempo,
//    o prego cai na metade, virar o celular apaga, inclinar derrete mais rápido,
//    chama sempre para cima, aviso no fim.
//  - "Sair da caixa": a caixa para com uma janela virada para a câmera,
//    e a câmera sai por ela. "Voltar para a vela" faz o caminho de volta.
//  - A cera tem a mesma física da aba 3D (CeraSimulacao.swift, desenhada pelo CeraEntidades.swift):
//    poça no topo sempre reta com o chão, pingos que escorrem e pingam para o lado contrário da chama,
//    gotas que caem no fundo da caixa, nas paredes ou na tampa e vão acumulando em montinhos
//    (os das paredes giram junto com a caixa), e a chama que derrete a borda em que encosta
//    e apaga se entrar na cera.
//  - No simulador não tem sensor: arrastar a vela inclina o "celular" e dois toques endireitam.
//
//  Usa o Movimento, o Haptics e o TamanhoVela que estão no ContentView.
//  Precisa de iOS 18 ou mais novo.

import SwiftUI
import UIKit
import Combine
import RealityKit

struct CaixaVelaView: View {
    enum Estado { case apagada, acesa, pausada, fim }

    /// Só monta a RealityView quando a aba está na tela (veja ContentView)
    var naTela = true

    @StateObject private var movimento = Movimento()
    @State private var haptics = Haptics()
    @State private var cena = CenaCaixa()

    @State private var tamanho: TamanhoVela = .media
    @State private var estado: Estado = .apagada
    @State private var queimado: TimeInterval = 0
    @State private var ultimoTick = Date()
    @State private var pregoCaiu = false
    @State private var fora = false
    @State private var ultimoPingo = Date.distantPast   // para não vibrar demais com muitas gotas juntas
    @State private var naTelaAgora = false              // só a aba que está na tela apaga com o sopro
    #if targetEnvironment(simulator)
    @State private var rolagemSimulada: Double = 0
    @State private var arfagemSimulada: Double = 0
    #endif

    private let relogio = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var progresso: Double { min(1, queimado / tamanho.duracao) }
    private var inclinado: Bool { movimento.inclinacao > 0.45 }
    private var alturaEmMetros: Float { Float(tamanho.altura) / 1500 }

    /// A cena que vai para uma RealityView nova. Na primeira vez é a própria `cena`. Nas outras
    /// (voltando para esta aba) é uma cena com entidades NOVAS que continua de onde a antiga parou.
    /// Entidades que já estiveram numa RealityView que sumiu não aparecem mais (a tela fica preta).
    private func cenaParaMontar() -> CenaCaixa {
        let nova = cena.montada ? CenaCaixa(continuando: cena) : cena
        nova.montada = true
        if nova !== cena { cena = nova }
        return nova
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if naTela {
                    RealityView { content in
                        content.camera = .virtual
                        content.add(cenaParaMontar().raiz)
                    }
                } else {
                    Color.black
                }
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
            .accessibilityLabel("Vela \(tamanho.rawValue.lowercased()) dentro da caixa")
            .accessibilityValue(textoEstado)

            controles
        }
        .background(Color.black)
        .onAppear { naTelaAgora = true; movimento.iniciar() }
        .onDisappear { naTelaAgora = false; movimento.parar(); haptics.pararChama() }
        .onReceive(relogio) { data in atualizar(data) }
        .onReceive(Sopro.compartilhado.soprou) { leitura in soprou(leitura) }
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
                Button(fora ? "Voltar para a vela" : "Sair da caixa") {
                    fora.toggle()
                    haptics.tique()
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            PainelSopro()

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

    // MARK: Ações (iguais às outras telas)

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

    // Alguém soprou no microfone (Sopro.swift): apaga a vela
    private func soprou(_ leitura: LeituraSopro) {
        guard naTelaAgora else { return }
        let apagou = estado == .acesa
        if apagou { apagar() }
        Sopro.compartilhado.registrar(leitura, aba: "Caixa", alturaChama: Double(cena.alturaDaChamaNaTela),
                                      alturaVela: max(0.06, 1 - progresso), apagou: apagou)
    }

    private func atualizar(_ data: Date) {
        defer { ultimoTick = data }

        // A física da cera e a cena andam sempre (a cera esfria e escorre mesmo com a vela apagada)
        cena.atualizar(agora: data,
                       progresso: Float(progresso),
                       acesa: estado == .acesa,
                       alturaCheia: alturaEmMetros,
                       gravidade: movimento.gravidadeNaCena,
                       fora: fora)

        // Gotas de cera batendo no fundo, nas paredes ou na tampa da caixa: uma batidinha leve
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

// MARK: - A cena

@MainActor
final class CenaCaixa {
    let raiz = Entity()

    private let camera = PerspectiveCamera()
    /// Onde a chama está na tela, de baixo (0) para cima (1). Serve para comparar com o sopro.
    private(set) var alturaDaChamaNaTela: Float = 0.5
    private let caixa = Entity()            // tudo que gira junto (paredes, tampa, fundo)
    let cera: CeraSimulacao                 // a física da cera (CeraSimulacao.swift)
    var montada = false                     // já foi colocada numa RealityView (veja cenaParaMontar)
    private let desenhoCera: CeraEntidades  // a vela, a poça, os pingos e os montinhos (CeraEntidades.swift)
    private let pavio: ModelEntity
    private let brilhoCera: ModelEntity
    private let mira = Entity()             // vira a chama para a câmera (e deixa ela inclinar)
    private let chama: ModelEntity
    private let prego = Entity()
    // Estrelas de luz desenhadas nas paredes do quarto (uma para cada furo da caixa)
    private struct EstrelaDeLuz {
        let lado: Int            // em qual lado da caixa está o furo (0 frente, 1 direita, 2 fundo, 3 esquerda)
        let centro: CGPoint      // centro do furo (no desenho de 14 cm)
        let raio: CGFloat        // tamanho do furo (no desenho de 14 cm)
        let entidade: ModelEntity
        var opacidade: Float = -1
    }
    private var estrelasDeLuz: [EstrelaDeLuz] = []
    private var texturaLuz: TextureResource?
    private let luzDentro = PointLight()

    // Estado
    private var ultimaData: Date?
    private var brilho: Float = 0
    private var zoom: Float = 0              // 0 = dentro da caixa, 1 = fora
    private var giro: Float = 0              // quanto a caixa já girou (radianos)
    private var pregoCaindo = false

    // Tamanhos (em metros)
    private let lado: Float = 0.7            // caixa
    private let espessura: Float = 0.02      // madeira
    private let base: Float = 0.02           // fundo da caixa
    private let raioVela: Float = 0.035
    private var escala: CGFloat { CGFloat(lado / 0.14) }   // os recortes são desenhados numa caixa de 14 cm
    private let centroJanela = CGPoint(x: 0, y: 0.05)      // janela grande do meio (no desenho de 14 cm)

    // Ajustes fáceis
    private let segundosPorVolta: Float = 90 // velocidade do giro da caixa
    private let lenteDentro: Float = 70
    private let lenteFora: Float = 50

    /// `velha`: a cena da RealityView anterior. A nova continua de onde ela parou
    /// (a mesma física da cera, o brilho, o giro da caixa, o prego), só que com entidades novas.
    init(continuando velha: CenaCaixa? = nil) {
        cera = velha?.cera ?? CeraSimulacao()
        camera.camera.fieldOfViewInDegrees = lenteDentro
        raiz.addChild(camera)

        // Quarto escuro
        let corParede = SimpleMaterial(color: UIColor(red: 0.55, green: 0.50, blue: 0.45, alpha: 1), roughness: 1, isMetallic: false)
        let chao = ModelEntity(mesh: .generatePlane(width: 5, depth: 5),
                               materials: [SimpleMaterial(color: UIColor(red: 0.22, green: 0.17, blue: 0.14, alpha: 1),
                                                          roughness: 0.9, isMetallic: false)])
        raiz.addChild(chao)
        let paredesDoQuarto: [(SIMD3<Float>, Float)] = [([0, 1.25, -1.2], 0),
                                                         ([-1.2, 1.25, 0], .pi / 2),
                                                         ([1.2, 1.25, 0], -.pi / 2)]
        for (posicao, angulo) in paredesDoQuarto {
            let parede = ModelEntity(mesh: .generatePlane(width: 5, height: 2.5), materials: [corParede])
            parede.position = posicao
            parede.orientation = simd_quatf(angle: angulo, axis: [0, 1, 0])
            raiz.addChild(parede)
        }

        // Vela, poça, pingos e montinhos (o zero do desenho é a base da vela, no fundo da caixa)
        desenhoCera = CeraEntidades(cera: cera, corCera: UIColor(red: 0.95, green: 0.90, blue: 0.82, alpha: 1),
                                    rugosidade: 0.45)
        desenhoCera.raiz.position = [0, base, 0]
        raiz.addChild(desenhoCera.raiz)

        var ceraAcesa = PhysicallyBasedMaterial()
        ceraAcesa.baseColor = .init(tint: UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1))
        ceraAcesa.emissiveColor = .init(color: UIColor(red: 1, green: 0.6, blue: 0.25, alpha: 1))
        ceraAcesa.emissiveIntensity = 0.4
        ceraAcesa.blending = .transparent(opacity: 0.3)
        brilhoCera = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: raioVela + 0.0002), materials: [ceraAcesa])
        raiz.addChild(brilhoCera)

        pavio = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.0012),
                            materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), isMetallic: false)])
        raiz.addChild(pavio)

        // Chama: imagem de chama. A "mira" olha para a câmera; a chama fica de frente para ela.
        chama = ModelEntity(mesh: .generatePlane(width: 0.026, height: 0.052),
                            materials: [CenaCaixa.materialImagem(CenaCaixa.texturaChama())])
        chama.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        mira.addChild(chama)
        raiz.addChild(mira)

        // Prego espetado na vela
        let metal = SimpleMaterial(color: .lightGray, roughness: 0.25, isMetallic: true)
        let haste = ModelEntity(mesh: .generateCylinder(height: 0.016, radius: 0.0012), materials: [metal])
        haste.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let cabeca = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.0035), materials: [metal])
        cabeca.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        cabeca.position = [0.008, 0, 0]
        prego.addChild(haste)
        prego.addChild(cabeca)
        raiz.addChild(prego)

        texturaLuz = velha?.texturaLuz ?? CenaCaixa.texturaEstrelaDeLuz()
        montarCaixa()
        raiz.addChild(caixa)

        // Brilho de dentro: alcança só o interior da caixa.
        // (Essa luz não faz sombra, então se ela fosse longe, iluminaria o quarto "atravessando" a madeira,
        //  e era isso que fazia aquele círculo de luz em volta da caixa.)
        luzDentro.light.color = UIColor(red: 1, green: 0.6, blue: 0.3, alpha: 1)
        luzDentro.light.attenuationRadius = 0.45
        luzDentro.light.intensity = 0
        raiz.addChild(luzDentro)

        let luzQuarto = PointLight()
        luzQuarto.light.intensity = 120
        luzQuarto.light.attenuationRadius = 8
        luzQuarto.position = [0, 2.5, 3]
        raiz.addChild(luzQuarto)

        if let velha {
            ultimaData = velha.ultimaData
            brilho = velha.brilho
            zoom = velha.zoom
            giro = velha.giro
            if velha.pregoCaindo {
                pregoCaindo = true
                prego.transform = pregoNoChao
            }
        }
    }

    // MARK: Caixa com padrões

    private func montarCaixa() {
        let madeira = SimpleMaterial(color: UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1), roughness: 0.9, isMetallic: false)

        let fundo = ModelEntity(mesh: .generateBox(width: lado, height: base, depth: lado), materials: [madeira])
        fundo.position = [0, base / 2, 0]
        caixa.addChild(fundo)

        // Paredes lisas, só com poucas estrelas (frente, direita, fundo, esquerda).
        // Cada parede tem uma estrela maior no meio: é a "janela" por onde a câmera passa.
        let estrelasPorLado: [[(CGPoint, CGFloat)]] = [
            [(centroJanela, 0.03), (CGPoint(x: 0.04, y: 0.11), 0.01)],
            [(centroJanela, 0.03), (CGPoint(x: -0.035, y: 0.105), 0.012), (CGPoint(x: 0.03, y: 0.12), 0.007)],
            [(centroJanela, 0.03), (CGPoint(x: -0.04, y: 0.115), 0.009)],
            [(centroJanela, 0.03), (CGPoint(x: 0.035, y: 0.105), 0.011), (CGPoint(x: -0.03, y: 0.12), 0.007)]
        ]
        for (i, estrelas) in estrelasPorLado.enumerated() {
            // Para cada furo, uma estrela de luz que vai aparecer na parede do quarto
            for (centro, raio) in estrelas {
                let luz = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [materialLuz(0)])
                luz.isEnabled = false
                raiz.addChild(luz)
                estrelasDeLuz.append(EstrelaDeLuz(lado: i, centro: centro, raio: raio, entidade: luz))
            }
            let parede = parede(estrelas: estrelas, material: madeira)
            parede.position = [0, 0, lado / 2]
            // "suporte" gira a parede em volta do centro da caixa
            let suporte = Entity()
            suporte.orientation = simd_quatf(angle: Float(i) * .pi / 2, axis: [0, 1, 0])
            suporte.addChild(parede)
            caixa.addChild(suporte)
        }

        // Tampa lisa
        let tampa = ModelEntity(mesh: .generateBox(width: lado, height: espessura, depth: lado), materials: [madeira])
        tampa.position = [0, lado + espessura / 2, 0]
        caixa.addChild(tampa)
    }

    // Parede com estrelas recortadas.
    // O RealityKit se confunde com peças que têm buracos no meio. Então a parede é feita em
    // FAIXAS horizontais que passam pelo meio de cada estrela: assim cada estrela vira dois
    // "dentes" nas bordas das faixas, e nenhuma peça tem buraco no meio.
    // (O desenho é feito grande, 10.000x, para as contas ficarem precisas, e depois diminuído.)
    private func parede(estrelas: [(CGPoint, CGFloat)], material: SimpleMaterial) -> Entity {
        let parede = Entity()
        let aumento = CGAffineTransform(scaleX: 10_000, y: 10_000)
        let tamanhoReal = escala / 10_000

        var furos = Path()
        for (centro, raio) in estrelas {
            furos.addPath(estrela(centro, raio))
        }
        furos = furos.applying(aumento)

        // Cortes: embaixo, no meio de cada estrela e em cima
        var cortes: [CGFloat] = [0, 0.14]
        for (centro, _) in estrelas where !cortes.contains(centro.y) {
            cortes.append(centro.y)
        }
        cortes.sort()

        var opcoes = MeshResource.ShapeExtrusionOptions()
        opcoes.extrusionMethod = .linear(depth: espessura)

        for i in 0..<(cortes.count - 1) {
            let faixa = Path(CGRect(x: -0.07, y: cortes[i], width: 0.14, height: cortes[i + 1] - cortes[i]))
            var pedaco = faixa.applying(aumento).subtracting(furos)
            pedaco = pedaco.applying(CGAffineTransform(scaleX: tamanhoReal, y: tamanhoReal))
            do {
                let mesh = try MeshResource(extruding: pedaco, extrusionOptions: opcoes)
                parede.addChild(ModelEntity(mesh: mesh, materials: [material]))
            } catch {
                print("Não deu para fazer um pedaço da parede: \(error)")
            }
        }
        return parede
    }

    // MARK: Formatos (c = centro, r = "raio" do formato)

    nonisolated private func circulo(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    nonisolated private func estrela(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let raio = i.isMultiple(of: 2) ? r : r * 0.45
            let a = Double(i) * .pi / 5 + .pi / 2
            let ponto = CGPoint(x: c.x + raio * CGFloat(cos(a)), y: c.y + raio * CGFloat(sin(a)))
            if i == 0 { p.move(to: ponto) } else { p.addLine(to: ponto) }
        }
        p.closeSubpath()
        return p
    }

    nonisolated private func lua(_ c: CGPoint, _ r: CGFloat) -> Path {
        let cheia = circulo(c, r)
        let corte = Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.85, width: 2 * r, height: 2 * r))
        return cheia.subtracting(corte)
    }

    nonisolated private func coracao(_ c: CGPoint, _ r: CGFloat) -> Path {
        let t = r * 2
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - t * 0.45))
        p.addCurve(to: CGPoint(x: c.x - t * 0.5, y: c.y + t * 0.15),
                   control1: CGPoint(x: c.x - t * 0.15, y: c.y - t * 0.2),
                   control2: CGPoint(x: c.x - t * 0.5, y: c.y - t * 0.1))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + t * 0.2),
                   control1: CGPoint(x: c.x - t * 0.5, y: c.y + t * 0.45),
                   control2: CGPoint(x: c.x - t * 0.1, y: c.y + t * 0.45))
        p.addCurve(to: CGPoint(x: c.x + t * 0.5, y: c.y + t * 0.15),
                   control1: CGPoint(x: c.x + t * 0.1, y: c.y + t * 0.45),
                   control2: CGPoint(x: c.x + t * 0.5, y: c.y + t * 0.45))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - t * 0.45),
                   control1: CGPoint(x: c.x + t * 0.5, y: c.y - t * 0.1),
                   control2: CGPoint(x: c.x + t * 0.15, y: c.y - t * 0.2))
        p.closeSubpath()
        return p
    }

    // MARK: A cada quadro

    func atualizar(agora: Date, progresso: Float, acesa: Bool, alturaCheia: Float, gravidade: SIMD3<Float>, fora: Bool) {
        let dt = Float(min(0.1, agora.timeIntervalSince(ultimaData ?? agora)))
        ultimaData = agora
        let t = Float(agora.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))
        let n1 = ruido(t)
        let n2 = ruido(t * 1.7 + 10)

        // Chama acende e apaga devagar
        brilho += ((acesa ? 1 : 0) - brilho) * 0.15
        let b = max(0.001, brilho)

        // Vela derretendo: a altura (o timer) diminui e a física da cera faz o resto.
        // O fundo, as paredes e a tampa da caixa são onde as gotas podem cair (as paredes giram com a caixa).
        let alturaAtual = alturaCheia * max(0.06, 1 - progresso)
        cera.superficies = superficiesDaCaixa()
        cera.passo(.init(agora: agora, alturaCheia: alturaCheia, alturaPavio: alturaAtual,
                         brilho: brilho, acesa: acesa, gravidade: gravidade))
        desenhoCera.atualizar(brilho: brilho)
        brilhoCera.position = [0, base + alturaAtual - 0.015, 0]
        brilhoCera.isEnabled = brilho > 0.05

        // Pavio: sai do fundo da poça e vai até a ponta, onde fica a chama
        let pontaPavio = cera.pivoDaChama(alturaPavio: alturaAtual) + SIMD3(0, base, 0)
        let fundo = base + cera.topo[0] - 0.001
        let comprimento = max(0.004, pontaPavio.y - fundo)
        pavio.scale = [1, comprimento / 0.012, 1]
        pavio.position = [0, fundo + comprimento / 2, 0]

        // Chama: SEMPRE para cima no mundo (mesmo com o celular virado), virada para a câmera.
        // Quando encosta na cera, vai sendo abafada e encolhe.
        let paraCima = cera.cima
        let centroChama = pontaPavio + paraCima * 0.022
        let olho = camera.position(relativeTo: nil)
        var cimaDaImagem = paraCima
        if abs(simd_dot(simd_normalize(olho - centroChama), paraCima)) > 0.98 {
            cimaDaImagem = simd_normalize(paraCima + SIMD3(0.2, 0, 0))   // chama apontando bem para a câmera
        }
        mira.look(at: olho, from: centroChama, upVector: cimaDaImagem, relativeTo: nil)
        let tamanhoChama = b * (1 - 0.6 * cera.abafamento)
        chama.scale = [tamanhoChama * (1 - 0.05 * n2), tamanhoChama * (1 + 0.08 * n1), tamanhoChama]
        mira.isEnabled = brilho > 0.02

        luzDentro.position = pontaPavio + paraCima * 0.04
        luzDentro.light.intensity = 900 * brilho * (1 + 0.05 * n1)

        // Prego espetado na metade da vela (até cair)
        if !pregoCaindo {
            prego.position = [raioVela + 0.004, base + alturaCheia * 0.5, 0]
        }

        let giroAntes = giro
        girarEMoverCamera(dt: dt, fora: fora, centroChama: centroChama)
        alturaDaChamaNaTela = camera.alturaNaTela(centroChama)
        var girou = giro - giroAntes
        if girou < -.pi { girou += 2 * .pi }
        cera.girarManchasNasParedes(girou)       // montinhos nas paredes giram junto com a caixa
        atualizarEstrelasDeLuz(chama: centroChama)
    }

    // Onde as gotas de cera podem cair, nas coordenadas da vela (o zero é a base dela, no fundo da caixa)
    private func superficiesDaCaixa() -> [CeraSimulacao.Superficie] {
        let dentro = lado / 2 - espessura / 2              // face de dentro das paredes
        var lista: [CeraSimulacao.Superficie] = [
            .init(ponto: [0, 0, 0], normal: [0, 1, 0], raio: nil),              // fundo da caixa
            .init(ponto: [0, lado - base, 0], normal: [0, -1, 0], raio: nil)    // tampa, por baixo
        ]
        for i in 0..<4 {
            let g = simd_quatf(angle: giro + Float(i) * .pi / 2, axis: [0, 1, 0])
            lista.append(.init(ponto: g.act([0, 0, dentro]), normal: g.act([0, 0, -1]), raio: nil))
        }
        return lista
    }

    // MARK: Teatro de sombras: onde a luz de cada estrela cai no quarto
    //
    // Para cada furo: traçamos uma linha reta saindo da chama e passando pelo furo,
    // e vemos onde ela bate (parede do fundo, da esquerda, da direita ou chão).
    // Ali desenhamos a estrela de luz, do tamanho e com a inclinação certos.
    // Como é desenhada (e não uma sombra calculada pela luz), fica sempre nítida.

    private func atualizarEstrelasDeLuz(chama f: SIMD3<Float>) {
        let paredeLonge: Float = 1.2      // distância das paredes do quarto até o centro
        for i in estrelasDeLuz.indices {
            let estrela = estrelasDeLuz[i]
            let giroDoLado = simd_quatf(angle: giro + Float(estrela.lado) * .pi / 2, axis: [0, 1, 0])
            let furo = giroDoLado.act(SIMD3<Float>(Float(estrela.centro.x * escala),
                                                   Float(estrela.centro.y * escala),
                                                   lado / 2))
            let normalDoFuro = giroDoLado.act(SIMD3<Float>(0, 0, 1))
            let direcao = simd_normalize(furo - f)

            // Onde a linha bate no quarto?
            var melhorT = Float.greatestFiniteMagnitude
            var normalDaParede = SIMD3<Float>(0, 0, 1)
            func testar(_ t: Float, _ normal: SIMD3<Float>) {
                guard t > 0, t < melhorT else { return }
                let ponto = f + direcao * t
                guard ponto.y >= 0, ponto.y <= 2.5, abs(ponto.x) <= paredeLonge + 0.01, ponto.z >= -paredeLonge - 0.01 else { return }
                melhorT = t
                normalDaParede = normal
            }
            if direcao.z < -0.001 { testar((-paredeLonge - f.z) / direcao.z, [0, 0, 1]) }   // parede do fundo
            if direcao.x < -0.001 { testar((-paredeLonge - f.x) / direcao.x, [1, 0, 0]) }   // parede da esquerda
            if direcao.x > 0.001 { testar((paredeLonge - f.x) / direcao.x, [-1, 0, 0]) }    // parede da direita
            if direcao.y < -0.001 { testar((0 - f.y) / direcao.y, [0, 1, 0]) }              // chão

            let distanciaAteFuro = simd_length(furo - f)
            guard melhorT < .greatestFiniteMagnitude, distanciaAteFuro > 0.01 else {
                estrela.entidade.isEnabled = false     // essa luz vai para o lado da câmera (não tem parede)
                continue
            }

            let ponto = f + direcao * melhorT
            let cosFuro = abs(simd_dot(direcao, normalDoFuro))       // furo de frente ou de lado para a chama
            let cosParede = abs(simd_dot(direcao, normalDaParede))   // luz batendo reta ou de lado na parede

            // Tamanho: quanto mais longe a parede, maior a estrela (como no teatro de sombras de verdade)
            let raioNaParede = Float(estrela.raio * escala) * (melhorT / distanciaAteFuro)
            let tamanho = raioNaParede / 0.38                        // a estrela ocupa 38% da imagem
            let esticar = min(3, max(0.3, cosFuro / max(cosParede, 0.2)))

            estrela.entidade.position = ponto + normalDaParede * 0.004
            estrela.entidade.orientation = simd_quatf(from: [0, 0, 1], to: normalDaParede)
            estrela.entidade.scale = [tamanho * esticar, tamanho, 1]

            // Some devagar quando a luz bate muito de lado (ou quando a vela apaga)
            let opacidade = brilho * min(1, cosParede * 2.5) * min(1, cosFuro * 2.5)
            estrela.entidade.isEnabled = opacidade > 0.02
            if abs(opacidade - estrela.opacidade) > 0.03 {
                estrela.entidade.model?.materials = [materialLuz(opacidade)]
                estrelasDeLuz[i].opacidade = opacidade
            }
        }
    }

    private func materialLuz(_ opacidade: Float) -> UnlitMaterial {
        var m = UnlitMaterial()
        if let texturaLuz {
            m.color = .init(tint: .white, texture: .init(texturaLuz))
        }
        m.blending = .transparent(opacity: .init(scale: max(0, min(1, opacidade))))
        m.opacityThreshold = 0.01
        return m
    }

    // Imagem da estrela de luz: estrela quente, nítida, com um brilho suave em volta
    private static func texturaEstrelaDeLuz() -> TextureResource? {
        let tam = CGSize(width: 512, height: 512)
        let imagem = UIGraphicsImageRenderer(size: tam).image { contexto in
            let c = contexto.cgContext
            let centro = CGPoint(x: 256, y: 256)
            func estrela(_ r: CGFloat) -> UIBezierPath {
                let p = UIBezierPath()
                for i in 0..<10 {
                    let raio = i.isMultiple(of: 2) ? r : r * 0.45
                    let a = Double(i) * .pi / 5 + .pi / 2
                    let ponto = CGPoint(x: centro.x + raio * CGFloat(cos(a)), y: centro.y - raio * CGFloat(sin(a)))
                    if i == 0 { p.move(to: ponto) } else { p.addLine(to: ponto) }
                }
                p.close()
                return p
            }
            let cor = UIColor(red: 1, green: 0.78, blue: 0.5, alpha: 1)
            // brilho suave em volta
            c.setShadow(offset: .zero, blur: 28, color: cor.withAlphaComponent(0.7).cgColor)
            cor.withAlphaComponent(0.8).setFill()
            estrela(194).fill()
            // miolo um pouco mais claro (a luz é mais forte no meio)
            c.setShadow(offset: .zero, blur: 40, color: UIColor(red: 1, green: 0.92, blue: 0.75, alpha: 0.6).cgColor)
            UIColor(red: 1, green: 0.9, blue: 0.72, alpha: 0.35).setFill()
            estrela(120).fill()
        }
        guard let cg = imagem.cgImage else { return nil }
        return try? TextureResource(image: cg, options: .init(semantic: .color))
    }

    // A caixa gira devagar. Para a câmera entrar ou sair, ela para com uma janela virada para a câmera.
    private func girarEMoverCamera(dt: Float, fora: Bool, centroChama: SIMD3<Float>) {
        let quartoDeVolta = Float.pi / 2
        let alvoZoom: Float = fora ? 1 : 0

        if zoom != alvoZoom {
            // Termina de girar até a próxima janela ficar de frente para a câmera
            let alvoGiro = (giro / quartoDeVolta).rounded(.up) * quartoDeVolta
            giro = min(alvoGiro, giro + dt * 0.8)
            if giro >= alvoGiro - 0.0001 {
                // Janela alinhada: a câmera passa (leva uns 3 segundos)
                zoom += (alvoZoom > zoom ? 1 : -1) * dt / 3
                zoom = max(0, min(1, zoom))
            }
        } else {
            giro += dt * 2 * .pi / segundosPorVolta
        }
        if giro >= 2 * .pi { giro -= 2 * .pi }
        caixa.orientation = simd_quatf(angle: giro, axis: [0, 1, 0])

        // Caminho da câmera: dentro (vendo a vela inteira) -> janela da frente -> fora
        let suave = zoom * zoom * (3 - 2 * zoom)
        let alturaJanela = Float(centroJanela.y * escala)
        let dentro: SIMD3<Float> = [0, alturaJanela + 0.05, 0.27]   // um pouco de cima, para ver a poça no topo
        let janela: SIMD3<Float> = [0, alturaJanela, lado / 2 + 0.05]
        let longe: SIMD3<Float> = [0.25, 1.1, 3.2]
        let posicao = suave < 0.15
            ? mix(dentro, janela, t: suave / 0.15)
            : mix(janela, longe, t: (suave - 0.15) / 0.85)
        let meioDaVela: SIMD3<Float> = [0, base + (centroChama.y - base) * 0.6, 0]
        camera.look(at: mix(meioDaVela, [0, 0.5, -0.5], t: suave), from: posicao, relativeTo: nil)
        camera.camera.fieldOfViewInDegrees = lenteDentro + (lenteFora - lenteDentro) * suave
    }

    // MARK: Prego

    func derrubarPrego() {
        pregoCaindo = true
        prego.move(to: pregoNoChao, relativeTo: raiz, duration: Haptics.tempoQueda, timingFunction: .easeIn)
    }

    // Onde o prego fica depois de cair
    private var pregoNoChao: Transform {
        var destino = prego.transform
        destino.translation = [0.06, base + 0.004, 0.05]
        destino.rotation = simd_quatf(angle: 0.8, axis: [0, 1, 0])
        return destino
    }

    func recolocarPrego() {
        pregoCaindo = false
        prego.stopAllAnimations()
        prego.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }

    // MARK: Ajudantes

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * max(0, min(1, t))
    }

    private func ruido(_ t: Float) -> Float {
        sin(t * 7.3) * 0.5 + sin(t * 13.1 + 1.3) * 0.3 + sin(t * 23.7 + 2.1) * 0.2
    }

    private static func materialImagem(_ textura: TextureResource?) -> UnlitMaterial {
        var m = UnlitMaterial()
        if let textura {
            m.color = .init(tint: .white, texture: .init(textura))
        }
        m.blending = .transparent(opacity: 1.0)
        // Partes totalmente transparentes da imagem são ignoradas.
        // Sem isso, o "quadrado" invisível da imagem tampava o que estava atrás (aquele preto perto da chama).
        m.opacityThreshold = 0.02
        return m
    }

    // Chama em forma de gota: base azulada, corpo laranja, ponta amarela sumindo e miolo branco
    private static func texturaChama() -> TextureResource? {
        let tam = CGSize(width: 128, height: 256)
        let w = tam.width, h = tam.height
        let imagem = UIGraphicsImageRenderer(size: tam).image { contexto in
            let c = contexto.cgContext
            let gota = UIBezierPath()
            gota.move(to: CGPoint(x: w / 2, y: 0))
            gota.addCurve(to: CGPoint(x: w * 0.9, y: h * 0.72),
                          controlPoint1: CGPoint(x: w * 0.62, y: h * 0.3), controlPoint2: CGPoint(x: w * 0.9, y: h * 0.5))
            gota.addCurve(to: CGPoint(x: w / 2, y: h),
                          controlPoint1: CGPoint(x: w * 0.9, y: h * 0.9), controlPoint2: CGPoint(x: w * 0.74, y: h))
            gota.addCurve(to: CGPoint(x: w * 0.1, y: h * 0.72),
                          controlPoint1: CGPoint(x: w * 0.26, y: h), controlPoint2: CGPoint(x: w * 0.1, y: h * 0.9))
            gota.addCurve(to: CGPoint(x: w / 2, y: 0),
                          controlPoint1: CGPoint(x: w * 0.1, y: h * 0.5), controlPoint2: CGPoint(x: w * 0.38, y: h * 0.3))
            gota.close()
            c.saveGState()
            gota.addClip()
            let espaco = CGColorSpaceCreateDeviceRGB()
            let cores = [UIColor(red: 1, green: 0.85, blue: 0.45, alpha: 0).cgColor,
                         UIColor(red: 1, green: 0.62, blue: 0.18, alpha: 0.95).cgColor,
                         UIColor(red: 1, green: 0.45, blue: 0.10, alpha: 0.95).cgColor,
                         UIColor(red: 0.35, green: 0.45, blue: 1, alpha: 0.7).cgColor] as CFArray
            if let corpo = CGGradient(colorsSpace: espaco, colors: cores, locations: [0, 0.35, 0.82, 1]) {
                c.drawLinearGradient(corpo, start: CGPoint(x: w / 2, y: 0), end: CGPoint(x: w / 2, y: h), options: [])
            }
            // Miolo claro em forma de gota (alongado), e não uma bolinha redonda
            let gotinha = UIBezierPath()
            gotinha.move(to: CGPoint(x: w / 2, y: h * 0.32))
            gotinha.addCurve(to: CGPoint(x: w / 2, y: h * 0.9),
                             controlPoint1: CGPoint(x: w * 0.72, y: h * 0.55), controlPoint2: CGPoint(x: w * 0.7, y: h * 0.9))
            gotinha.addCurve(to: CGPoint(x: w / 2, y: h * 0.32),
                             controlPoint1: CGPoint(x: w * 0.3, y: h * 0.9), controlPoint2: CGPoint(x: w * 0.28, y: h * 0.55))
            gotinha.close()
            gotinha.addClip()
            let coresMiolo = [UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 0).cgColor,
                              UIColor(red: 1, green: 0.97, blue: 0.85, alpha: 0.9).cgColor,
                              UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 0.5).cgColor] as CFArray
            if let miolo = CGGradient(colorsSpace: espaco, colors: coresMiolo, locations: [0, 0.55, 1]) {
                c.drawLinearGradient(miolo, start: CGPoint(x: w / 2, y: h * 0.32), end: CGPoint(x: w / 2, y: h * 0.9), options: [])
            }
            c.restoreGState()
        }
        guard let cg = imagem.cgImage else { return nil }
        return try? TextureResource(image: cg, options: .init(semantic: .color))
    }
}

#Preview {
    CaixaVelaView()
}

