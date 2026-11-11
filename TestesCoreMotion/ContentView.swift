//  ContentView.swift
//  Teste realista da vela: Core Motion + Core Haptics + luz e sombra.
//
//  O que dá para testar:
//  - Escolher o tamanho (pequena / média / grande): o tamanho é o tempo.
//  - Acender: a chama cresce, ilumina a parede, a mesa e a cera.
//  - A vela derrete, a cera escorre pelas laterais e se espalha no prato.
//  - Sombra: o passarinho na mesa faz sombra na parede. Conforme a vela
//    baixa, a luz desce e a sombra fica MAIOR (é o tempo passando).
//  - Prego na metade: quando a cera chega nele, ele se solta, cai, bate no prato
//    e quica (vibração e som no momento da batida).
//  - Chama sempre para cima: incline o celular e a chama continua apontando para cima.
//  - Inclinar muito (de lado): a vela derrete mais rápido.
//  - Virar de cabeça para baixo: a chama apaga (com fumacinha) e o tempo pausa.
//    Ela continua apagada quando o celular desvira: para continuar, é só acender de novo.
//  - Fim: a vela apaga com uma vibração forte que vai sumindo.
//  - Se o "Reduzir movimento" do iPhone estiver ligado, a chama quase não treme.
//  - VoiceOver: fala o estado sem números e deixa trocar o tamanho deslizando para cima/baixo.
//
//  Sons e vibrações: ficam nos arquivos .ahap e .wav da pasta "SonsEVibracoes".
//  Eles precisam estar dentro do projeto do Xcode (com o target marcado).
//
//  ⚠️ Teste num iPhone de verdade: o simulador não vibra nem sente movimento.
//  Tempos curtos só para teste: pequena 30 s, média 60 s, grande 120 s.

import SwiftUI
import Combine
import CoreMotion
import CoreHaptics
import AVFoundation

// MARK: - Tela principal (o MyApp chama esta)
// Três abas para comparar os testes:
// - 2D: a vela desenhada (VelaRealistaView, neste arquivo)
// - 3D: a vela no RealityKit (RealityVelaView.swift)
// - Caixa: a vela dentro da caixa, "out of the box" (CaixaVelaView.swift)
// ⚠️ Precisa de iOS 18 ou mais novo (Minimum Deployments: 18.0)

struct ContentView: View {
    enum Aba { case vela2D, vela3D, caixa }

    // A TabView deixa vivas as telas das abas que já foram abertas. Se a RealityView da Caixa
    // continuar viva escondida, a da 3D aparece toda preta (e o contrário também): o RealityKit
    // só desenha a primeira cena. Por isso cada aba 3D só monta a sua RealityView enquanto está
    // na tela (o resto, como a vela acesa e o tempo, continua guardado).
    @State private var aba = Aba.vela2D

    var body: some View {
        TabView(selection: $aba) {
            Tab("2D", systemImage: "flame", value: Aba.vela2D) { VelaRealistaView() }
            Tab("3D", systemImage: "cube", value: Aba.vela3D) { RealityVelaView(naTela: aba == .vela3D) }
            Tab("Caixa", systemImage: "shippingbox", value: Aba.caixa) { CaixaVelaView(naTela: aba == .caixa) }
        }
    }
}

// MARK: - Tamanho da vela = tempo

enum TamanhoVela: String, CaseIterable, Identifiable {
    case pequena = "Pequena"
    case media = "Média"
    case grande = "Grande"

    var id: String { rawValue }

    var duracao: TimeInterval {
        switch self {
        case .pequena: return 30
        case .media: return 60
        case .grande: return 120
        }
    }

    var altura: CGFloat {
        switch self {
        case .pequena: return 200
        case .media: return 280
        case .grande: return 360
        }
    }
}

// MARK: - Tela da vela

struct VelaRealistaView: View {
    enum Estado { case apagada, acesa, pausada, fim }

    @StateObject private var movimento = Movimento()
    @State private var haptics = Haptics()
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento
    @Environment(\.scenePhase) private var fase

    @State private var tamanho: TamanhoVela = .media
    @State private var estado: Estado = .apagada
    @State private var queimado: TimeInterval = 0   // quanto tempo a vela já queimou
    @State private var ultimoTick = Date()
    @State private var acendeuEm: Date?
    @State private var apagouEm: Date?
    @State private var pregoCaiuEm: Date?
    @State private var naTelaAgora = false             // só a aba que está na tela apaga com o sopro
    @State private var alturaTela: CGFloat = 800       // para saber a altura da chama na tela

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var progresso: Double { min(1, queimado / tamanho.duracao) }   // 0 = inteira, 1 = acabou
    private var inclinado: Bool { abs(movimento.angulo) > 0.45 }            // mais ou menos 25 graus
    private var calmo: Bool { reduzirMovimento }

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { linhaDoTempo in
                Canvas { ctx, size in
                    desenhar(&ctx, size, linhaDoTempo.date)
                }
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alturaTela = $0 }
            .accessibilityElement()
            .accessibilityLabel("Vela \(tamanho.rawValue.lowercased())")
            .accessibilityValue(textoEstado)
            .accessibilityHint("Deslize para cima ou para baixo para mudar o tamanho")
            .accessibilityAdjustableAction { direcao in
                guard estado == .apagada || estado == .fim else { return }
                let todos = TamanhoVela.allCases
                guard let i = todos.firstIndex(of: tamanho) else { return }
                switch direcao {
                case .increment: if i < todos.count - 1 { tamanho = todos[i + 1] }
                case .decrement: if i > 0 { tamanho = todos[i - 1] }
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Acender") { acender() }

            controles
        }
        .background(Color.black)
        .onAppear { naTelaAgora = true; movimento.iniciar() }
        .onDisappear { naTelaAgora = false; movimento.parar(); haptics.pararChama() }
        .onReceive(tick) { agora in atualizar(agora) }
        .onReceive(Sopro.compartilhado.soprou) { leitura in soprou(leitura) }
        // Como no exemplo da Apple: desliga o motor de vibração quando o app sai da tela
        // e liga de novo quando volta (economiza bateria).
        .onChange(of: fase) { _, novaFase in
            switch novaFase {
            case .background: haptics.desligarMotor()
            case .active:
                haptics.ligarMotor()
                if estado == .acesa { haptics.iniciarChama() }
            default: break
            }
        }
        .onChange(of: movimento.invertido) { _, invertido in
            // Virar apaga a vela. Desvirar NÃO acende: a pessoa acende de novo quando quiser.
            if invertido { pausar() }
        }
        .onChange(of: tamanho) { _, _ in
            haptics.tique()
            if estado == .fim { recomecar() }
        }
    }

    // MARK: Controles (embaixo da tela)

    private var controles: some View {
        VStack(spacing: 12) {
            Text(textoEstado)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            if estado == .apagada || estado == .fim {
                Picker("Tamanho", selection: $tamanho) {
                    ForEach(TamanhoVela.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                if estado != .acesa {
                    // Pausada: acende de novo e continua de onde parou
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

            PainelSopro()

            if !haptics.suportado {
                Text("Este aparelho não tem vibração (Core Haptics)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    // Texto sem números, que também é o que o VoiceOver fala
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
            pregoCaiuEm = nil
        }
        estado = .acesa
        acendeuEm = Date()
        apagouEm = nil
        ultimoTick = Date()
        haptics.acender()
        haptics.iniciarChama()
    }

    private func recomecar() {
        let estavaAcesa = (estado == .acesa)
        haptics.pararChama()
        if estavaAcesa { haptics.apagar() }
        estado = .apagada
        queimado = 0
        pregoCaiuEm = nil
        acendeuEm = nil
        apagouEm = estavaAcesa ? Date() : nil
    }

    private func pausar() {
        guard estado == .acesa else { return }
        estado = .pausada
        apagouEm = Date()
        haptics.pararChama()
        haptics.apagar()
    }

    // Alguém soprou no microfone (Sopro.swift): apaga como quando vira o celular
    private func soprou(_ leitura: LeituraSopro) {
        guard naTelaAgora else { return }
        let apagou = estado == .acesa
        if apagou { pausar() }
        Sopro.compartilhado.registrar(leitura, aba: "2D", alturaChama: alturaDaChamaNaTela,
                                      alturaVela: 1 - progresso, apagou: apagou)
    }

    // A mesma conta do desenho: onde fica o meio da chama, de baixo (0) para cima (1)
    private var alturaDaChamaNaTela: Double {
        let altura = max(16, tamanho.altura * CGFloat(1 - progresso))
        let meioDaChama = alturaTela * 0.70 - 6 - altura - 14 - 22
        return Double(1 - meioDaChama / max(1, alturaTela))
    }

    private func atualizar(_ agora: Date) {
        defer { ultimoTick = agora }
        guard estado == .acesa else { return }

        // Inclinada, a vela derrete mais rápido
        let passou = min(0.5, agora.timeIntervalSince(ultimoTick))
        queimado += passou * (inclinado ? 2.5 : 1)

        // Como a bolinha do exemplo da Apple: quanto mais inclinado, mais forte a chama vibra
        haptics.atualizarChama(inclinacao: Float(min(1, abs(movimento.angulo))))

        if progresso >= 0.5 && pregoCaiuEm == nil {
            pregoCaiuEm = agora
            // Vela maior = prego cai de mais alto = batida mais forte
            let queda = Float(tamanho.altura / TamanhoVela.grande.altura)
            haptics.prego(forca: queda)
        }

        if progresso >= 1 {
            estado = .fim
            apagouEm = agora
            haptics.pararChama()
            haptics.fim()
        }
    }

    // MARK: - Desenho

    private func desenhar(_ ctx: inout GraphicsContext, _ size: CGSize, _ agora: Date) {
        let t = agora.timeIntervalSinceReferenceDate
        let cx = size.width / 2
        let chao = size.height * 0.70            // onde a vela e o passarinho encostam na mesa
        let paredeFim = chao - 40                // onde a parede encontra a mesa
        let largura: CGFloat = 86
        let alturaCheia = tamanho.altura
        let altura = max(16, alturaCheia * CGFloat(1 - progresso))
        let base = chao - 6
        let topo = base - altura
        let pavioTopo = topo - 14
        let amp: Double = calmo ? 0.12 : 1        // quanto a chama treme
        let n1 = ruido(t)
        let n2 = ruido(t * 1.7 + 10)

        // Brilho da chama (0 = apagada, 1 = acesa). Sobe ao acender e desce ao apagar.
        var brilho: Double = 0
        if estado == .acesa {
            brilho = min(1, agora.timeIntervalSince(acendeuEm ?? agora) / 0.6)
        } else if let apagou = apagouEm {
            brilho = max(0, 1 - agora.timeIntervalSince(apagou) / 0.5)
        }
        let tremor = brilho * (1 + 0.06 * n1 * amp)

        // Parede
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: paredeFim)),
                 with: .color(Color(red: 0.07, green: 0.055, blue: 0.05)))

        // Mesa
        ctx.fill(Path(CGRect(x: 0, y: paredeFim, width: size.width, height: size.height - paredeFim)),
                 with: .linearGradient(Gradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.07),
                                                         Color(red: 0.06, green: 0.04, blue: 0.03)]),
                                       startPoint: CGPoint(x: 0, y: paredeFim),
                                       endPoint: CGPoint(x: 0, y: size.height)))

        // Luz da chama na parede e na mesa
        let chamaCentro = CGPoint(x: cx, y: pavioTopo - 22)
        if brilho > 0 {
            let raioLuz: CGFloat = 340 * CGFloat(tremor)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.62, blue: 0.25).opacity(0.42 * brilho),
                                                             Color(red: 1, green: 0.50, blue: 0.20).opacity(0.12 * brilho),
                                                             .clear]),
                                           center: chamaCentro, startRadius: 0, endRadius: raioLuz))
        }

        // Sombra do passarinho na parede: firme (não treme) e cresce conforme a vela baixa
        let objX = cx - 100
        let objTam: CGFloat = 54
        let passaro = ctx.resolve(Image(systemName: "bird.fill"))
        if brilho > 0 {
            let escala = 1.4 + 1.2 * CGFloat(progresso)
            let s = objTam * escala
            let sombraRect = CGRect(x: objX - s / 2 - 20 * (escala - 1), y: paredeFim - s, width: s, height: s)
            var camada = ctx
            camada.opacity = 0.8 * brilho
            camada.addFilter(.blur(radius: 1.5 + 2 * CGFloat(progresso)))
            var sombra = passaro
            sombra.shading = .color(.black)
            camada.draw(sombra, in: sombraRect)
        }

        // O passarinho em cima da mesa
        var objeto = passaro
        objeto.shading = .color(Color(white: 0.12 + 0.25 * brilho))
        ctx.draw(objeto, in: CGRect(x: objX - objTam / 2, y: chao - objTam, width: objTam, height: objTam))

        // Prato
        let prato = CGRect(x: cx - 85, y: chao - 14, width: 170, height: 26)
        ctx.fill(Path(ellipseIn: prato),
                 with: .linearGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0.25)]),
                                       startPoint: CGPoint(x: cx, y: prato.minY),
                                       endPoint: CGPoint(x: cx, y: prato.maxY)))
        ctx.fill(Path(ellipseIn: prato.insetBy(dx: 10, dy: 4)), with: .color(Color(white: 0.32)))

        // Cera derretida espalhada no prato
        let poca = CGFloat(progresso)
        if poca > 0 {
            var cera = ctx
            cera.opacity = min(1, Double(poca) * 5)
            let r = 45 + 50 * poca
            cera.fill(Path(ellipseIn: CGRect(x: cx - r, y: chao - 8 - 4 * poca, width: 2 * r, height: 10 + 8 * poca)),
                      with: .color(Color(red: 0.93, green: 0.89, blue: 0.82)))
        }

        // Corpo da vela (com sombreado dos lados, para parecer redonda)
        let corpo = Path(roundedRect: CGRect(x: cx - largura / 2, y: topo, width: largura, height: altura), cornerRadius: 4)
        ctx.fill(corpo, with: .linearGradient(Gradient(stops: [
            .init(color: Color(red: 0.72, green: 0.66, blue: 0.58), location: 0),
            .init(color: Color(red: 0.97, green: 0.94, blue: 0.88), location: 0.35),
            .init(color: Color(red: 0.93, green: 0.88, blue: 0.80), location: 0.65),
            .init(color: Color(red: 0.62, green: 0.56, blue: 0.48), location: 1)
        ]), startPoint: CGPoint(x: cx - largura / 2, y: 0), endPoint: CGPoint(x: cx + largura / 2, y: 0)))

        // Luz atravessando a cera perto da chama
        if brilho > 0 {
            ctx.fill(corpo, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.6, blue: 0.25).opacity(0.45 * brilho), .clear]),
                                                  startPoint: CGPoint(x: cx, y: topo),
                                                  endPoint: CGPoint(x: cx, y: topo + 70)))
        }

        // Cera escorrendo pelas laterais
        let corCera = Color(red: 0.99, green: 0.97, blue: 0.93)
        let gotas: [(dx: CGFloat, tamanho: CGFloat, espessura: CGFloat)] = [(-0.36, 70, 9), (0.12, 45, 7), (0.34, 95, 10)]
        let fatorGota = CGFloat(min(1, progresso * 2.5))
        for g in gotas {
            let l = min(g.tamanho * fatorGota, altura - 12)
            guard l > 4 else { continue }
            let x = cx + g.dx * largura
            ctx.fill(Path(roundedRect: CGRect(x: x - g.espessura / 2, y: topo + 2, width: g.espessura, height: l),
                          cornerRadius: g.espessura / 2), with: .color(corCera))
            ctx.fill(Path(ellipseIn: CGRect(x: x - g.espessura * 0.65, y: topo + l - g.espessura * 0.6,
                                            width: g.espessura * 1.3, height: g.espessura * 1.3)), with: .color(corCera))
        }

        // Topo da vela com a poça de cera derretida
        let tampa = CGRect(x: cx - largura / 2, y: topo - 7, width: largura, height: 14)
        ctx.fill(Path(ellipseIn: tampa), with: .color(Color(red: 0.95, green: 0.91, blue: 0.84)))
        ctx.fill(Path(ellipseIn: tampa.insetBy(dx: 12, dy: 3)), with: .color(Color(red: 0.88, green: 0.80, blue: 0.68).opacity(0.9)))
        if brilho > 0 {
            ctx.fill(Path(ellipseIn: tampa.insetBy(dx: 12, dy: 3)), with: .color(Color(red: 1, green: 0.7, blue: 0.3).opacity(0.35 * brilho)))
        }

        // Pavio
        var pavio = Path()
        pavio.move(to: CGPoint(x: cx, y: topo - 2))
        pavio.addQuadCurve(to: CGPoint(x: cx + 2, y: pavioTopo), control: CGPoint(x: cx - 2, y: topo - 9))
        ctx.stroke(pavio, with: .color(Color(white: 0.12)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        if brilho > 0 {
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 1, y: pavioTopo - 2, width: 5, height: 5)), with: .color(Color.orange.opacity(brilho)))
        }

        // Prego: espetado no meio da vela, ou caindo no prato
        let pregoInicio = CGPoint(x: cx + largura / 2 - 2, y: base - alturaCheia * 0.5)
        if let caiu = pregoCaiuEm {
            // 0 a 0,45 s: cai acelerando. Em 0,45 s bate no prato (mesmo momento da vibração forte).
            // De 0,45 a 0,65 s: dá um quiquezinho.
            let e: Double = agora.timeIntervalSince(caiu)
            let f: Double = min(1, e / Haptics.tempoQueda)
            let destino = CGPoint(x: cx + 58, y: chao - 6)
            let andouX: CGFloat = (destino.x - pregoInicio.x) * CGFloat(f)
            let andouY: CGFloat = (destino.y - pregoInicio.y) * CGFloat(f * f)
            var p = CGPoint(x: pregoInicio.x + andouX, y: pregoInicio.y + andouY)
            let quique: Double = (e - Haptics.tempoQueda) / 0.2
            if quique > 0 && quique < 1 {
                let pulo: Double = sin(quique * Double.pi) * 9
                p.y -= CGFloat(pulo)
            }
            desenharPrego(&ctx, em: p, angulo: f * .pi / 2)
        } else {
            desenharPrego(&ctx, em: pregoInicio, angulo: 0)
        }

        // Quarto escurece quando a vela está apagada
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55 * (1 - brilho))))

        // Chama
        if brilho > 0.01 {
            var c = ctx
            c.translateBy(x: cx + 2, y: pavioTopo + 4)
            c.rotate(by: .radians(max(-1, min(1, movimento.angulo))))   // chama sempre para cima
            c.scaleBy(x: brilho, y: brilho)                              // cresce ao acender, encolhe ao apagar

            let fh = 60 * CGFloat(1 + 0.10 * n1 * amp)
            let fw = 22 * CGFloat(1 - 0.06 * n2 * amp)
            let balanco = CGFloat(4 * n2 * amp)
            let fora = gota(altura: fh, largura: fw, ponta: balanco)

            var aura = c
            aura.addFilter(.blur(radius: 10))
            aura.fill(fora, with: .color(Color(red: 1, green: 0.55, blue: 0.15).opacity(0.8)))

            c.fill(fora, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.42, blue: 0.08),
                                                                 Color(red: 1, green: 0.72, blue: 0.28),
                                                                 Color(red: 1, green: 0.88, blue: 0.55).opacity(0.85)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: -fh)))

            var azul = c
            azul.addFilter(.blur(radius: 2))
            azul.fill(Path(ellipseIn: CGRect(x: -fw * 0.3, y: -fh * 0.12, width: fw * 0.6, height: fh * 0.14)),
                      with: .color(Color(red: 0.35, green: 0.5, blue: 1).opacity(0.6)))

            var miolo = c
            miolo.translateBy(x: 0, y: -fh * 0.06)
            miolo.fill(gota(altura: fh * 0.55, largura: fw * 0.5, ponta: balanco * 0.5),
                       with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.75), .white]),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: -fh * 0.55)))
        }

        // Fumacinha quando a vela apaga
        if let apagou = apagouEm, estado != .acesa {
            let e = agora.timeIntervalSince(apagou)
            if e < 3 {
                var fumaca = ctx
                fumaca.addFilter(.blur(radius: 4))
                for i in 0..<10 {
                    let fase = e - Double(i) * 0.12
                    guard fase > 0 else { continue }
                    let y = pavioTopo - CGFloat(fase) * 55
                    let x = cx + 2 + CGFloat(sin(fase * 3 + Double(i)) * 7 * fase)
                    let r = CGFloat(3 + fase * 7)
                    let op = max(0, 0.28 * (1 - fase / 2.4))
                    fumaca.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                with: .color(Color(white: 0.7).opacity(op)))
                }
            }
        }
    }

    private func desenharPrego(_ ctx: inout GraphicsContext, em ponto: CGPoint, angulo: Double) {
        var c = ctx
        c.translateBy(x: ponto.x, y: ponto.y)
        c.rotate(by: .radians(angulo))
        c.fill(Path(roundedRect: CGRect(x: 0, y: -1.5, width: 11, height: 3), cornerRadius: 1), with: .color(Color(white: 0.45)))
        c.fill(Path(ellipseIn: CGRect(x: 8, y: -5.5, width: 6, height: 11)),
               with: .linearGradient(Gradient(colors: [Color(white: 0.85), Color(white: 0.35)]),
                                     startPoint: CGPoint(x: 8, y: -5.5), endPoint: CGPoint(x: 14, y: 5.5)))
    }

    // Formato de gota da chama (a ponta pode balançar para os lados)
    private func gota(altura fh: CGFloat, largura fw: CGFloat, ponta: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: ponta, y: -fh))
        p.addCurve(to: CGPoint(x: fw / 2, y: -fh * 0.3),
                   control1: CGPoint(x: ponta + fw * 0.12, y: -fh * 0.72),
                   control2: CGPoint(x: fw / 2, y: -fh * 0.52))
        p.addCurve(to: CGPoint(x: 0, y: 0),
                   control1: CGPoint(x: fw / 2, y: -fh * 0.05),
                   control2: CGPoint(x: fw * 0.28, y: 0))
        p.addCurve(to: CGPoint(x: -fw / 2, y: -fh * 0.3),
                   control1: CGPoint(x: -fw * 0.28, y: 0),
                   control2: CGPoint(x: -fw / 2, y: -fh * 0.05))
        p.addCurve(to: CGPoint(x: ponta, y: -fh),
                   control1: CGPoint(x: -fw / 2, y: -fh * 0.52),
                   control2: CGPoint(x: ponta - fw * 0.12, y: -fh * 0.72))
        p.closeSubpath()
        return p
    }

    // "Ruído" suave entre -1 e 1, para a chama tremer de um jeito natural
    private func ruido(_ t: Double) -> Double {
        sin(t * 7.3) * 0.5 + sin(t * 13.1 + 1.3) * 0.3 + sin(t * 23.7 + 2.1) * 0.2
    }
}

// MARK: - Core Motion: inclinação e celular de cabeça para baixo

final class Movimento: ObservableObject {
    @Published var invertido = false
    @Published var angulo: Double = 0   // para onde fica "para cima" no mundo (em radianos)

    // Para a física da cera da aba 3D: a gravidade inteira, em 3D, sem limite nenhum.
    // Coordenadas do celular: x para a direita, y para o alto da tela, z saindo da tela.
    // Em pé normal: (0, -1, 0). Deitado de costas na mesa: (0, 0, -1).
    @Published var gravidade3D = SIMD3<Double>(0, -1, 0)

    // Para frente e para trás, conta como "em pé" o jeito que o celular estava quando a vela foi acesa
    // (assim dá para segurar o celular do jeito que for confortável). Para os lados não precisa:
    // todo mundo segura o celular reto para os lados.
    private(set) var arfagemBase: Double = 0

    /// A gravidade nas coordenadas das cenas 3D (y para cima, z para a câmera), de tamanho 1,
    /// já descontando o jeito que o celular estava (frente/trás) quando a vela foi acesa.
    var gravidadeNaCena: SIMD3<Float> {
        let g = gravidade3D
        let c = cos(arfagemBase), s = sin(arfagemBase)
        let v = SIMD3<Float>(Float(g.x), Float(g.y * c + g.z * s), Float(-g.y * s + g.z * c))
        let n = (v * v).sum().squareRoot()
        return n > 0.01 ? v / n : SIMD3(0, -1, 0)
    }

    /// Quanto a vela está inclinada em relação ao "para cima" do mundo (0 = reta, π = de cabeça para baixo).
    var inclinacao: Double { Double(acos(max(-1, min(1, -gravidadeNaCena.y)))) }

    /// O jeito que o celular está agora (para frente ou para trás) passa a ser o "em pé".
    func calibrar() {
        #if !targetEnvironment(simulator)
        let g = gravidade3D
        guard hypot(g.y, g.z) > 0.5 else { return }    // celular deitado de lado: deixa como estava
        arfagemBase = max(0, min(.pi / 2, atan2(-g.z, -g.y)))
        #endif
    }

    #if os(iOS)
    private let manager = CMMotionManager()
    private var mudouEm: Date?
    #endif

    // No simulador não tem sensor: a aba 3D finge a inclinação quando arrastamos o dedo.
    // rolagem = girar para os lados, arfagem = deitar para trás (positivo) ou para frente.
    #if targetEnvironment(simulator)
    func simular(rolagem a: Double, arfagem b: Double) {
        gravidade3D = SIMD3(-sin(a) * cos(b), -cos(a) * cos(b), -sin(b))
        angulo = max(-1.2, min(1.2, atan2(sin(a), cos(a))))
        invertido = gravidade3D.y > 0.8
    }
    #endif

    func iniciar() {
        #if os(iOS)
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0

        manager.startDeviceMotionUpdates(to: .main) { [weak self] dados, _ in
            guard let self, let g = dados?.gravity else { return }

            // Chama sempre para cima: ângulo entre o "para cima" da tela e o "para cima" do mundo.
            // Suavizado, para a chama não dar pulos.
            let alvo = max(-1.2, min(1.2, atan2(-g.x, -g.y)))
            self.angulo += (alvo - self.angulo) * 0.2

            // A gravidade em 3D, suavizada do mesmo jeito (e sempre com tamanho 1)
            var g3 = self.gravidade3D + (SIMD3(g.x, g.y, g.z) - self.gravidade3D) * 0.25
            let tamanho = (g3 * g3).sum().squareRoot()
            if tamanho > 0.01 { g3 /= tamanho; self.gravidade3D = g3 }

            // Em pé normal: g.y ≈ -1. De cabeça para baixo: g.y ≈ +1.
            // (Para testar "tela virada para baixo na mesa", troquem por: g.z > 0.8)
            let estaInvertido = g.y > 0.8

            // Só muda depois de meio segundo, para um giro sem querer não pausar
            if estaInvertido != self.invertido {
                if self.mudouEm == nil { self.mudouEm = Date() }
                if let mudouEm = self.mudouEm, Date().timeIntervalSince(mudouEm) > 0.5 {
                    self.invertido = estaInvertido
                    self.mudouEm = nil
                }
            } else {
                self.mudouEm = nil
            }
        }
        #endif
    }

    func parar() {
        #if os(iOS)
        manager.stopDeviceMotionUpdates()
        #endif
    }
}

// MARK: - Core Haptics: som e vibração juntos (como no exemplo "HapticRicochet" da Apple)
//
// O que veio da sessão "Practice Audio Haptic Design" (WWDC21):
// 1. Cada vibração fica num arquivo .ahap (Acender, Chama, Prego, Apagar, Fim).
//    Dá para ajustar a vibração sem mexer no código.
// 2. O som (.wav) está DENTRO do .ahap, então som e vibração tocam juntinhos.
// 3. Parâmetros dinâmicos: a força muda com o que acontece na tela
//    (inclinação mexe na chama, a altura da queda mexe no prego).
// 4. A chama é uma "textura" em loop, igual ao cascalho do exemplo.
// 5. O motor é ligado só quando precisa e desliga quando o app sai da tela.

final class Haptics {
    let suportado = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // Tempo que o prego leva para cair até o prato. Tem que ser igual ao "Time": 0.45 do Prego.ahap.
    static let tempoQueda: TimeInterval = 0.45

    private var engine: CHHapticEngine?
    private var precisaLigar = true
    private var players: [String: CHHapticPatternPlayer] = [:]
    private var chama: CHHapticAdvancedPatternPlayer?

    init() {
        criarMotor()
    }

    // MARK: Motor

    private func criarMotor() {
        guard suportado else { return }
        do {
            // .ambient: o som do app não para a música da pessoa.
            // Mas se o microfone estiver ligado (apagar soprando), o Sopro.swift já cuidou do áudio.
            if !Sopro.compartilhado.ligado {
                try? AVAudioSession.sharedInstance().setCategory(.ambient)
            }

            let motor = try CHHapticEngine(audioSession: .sharedInstance())

            // Se o motor parar (app em segundo plano, ligação, etc.), lembramos de ligar de novo
            motor.stoppedHandler = { [weak self] motivo in
                print("Motor de vibração parou: \(motivo.rawValue)")
                self?.precisaLigar = true
            }

            // Se o sistema reiniciar o motor, os players antigos não valem mais: carregamos tudo de novo
            motor.resetHandler = { [weak self] in
                print("Motor de vibração reiniciou")
                self?.precisaLigar = true
                self?.carregarPadroes()
            }

            engine = motor
            try ligarSePreciso()
            carregarPadroes()
        } catch {
            print("Erro ao criar o motor de vibração: \(error)")
        }
    }

    private func ligarSePreciso() throws {
        guard let engine, precisaLigar else { return }
        try engine.start()
        precisaLigar = false
    }

    func ligarMotor() {
        try? ligarSePreciso()
    }

    func desligarMotor() {
        pararChama()
        engine?.stop { [weak self] _ in self?.precisaLigar = true }
    }

    // MARK: Arquivos .ahap

    private func carregarPadroes() {
        guard let engine else { return }
        for nome in ["Acender", "Prego", "Apagar", "Fim"] {
            if let padrao = padrao(nome) {
                players[nome] = try? engine.makePlayer(with: padrao)
            }
        }
        if let padrao = padrao("Chama") {
            chama = try? engine.makeAdvancedPlayer(with: padrao)
            chama?.loopEnabled = true
        }
    }

    private func padrao(_ nome: String) -> CHHapticPattern? {
        guard let url = Bundle.main.url(forResource: nome, withExtension: "ahap") else {
            print("⚠️ Não achei \(nome).ahap. Ele foi adicionado ao projeto (com o target marcado)?")
            return nil
        }
        do {
            let dados = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: dados)
            guard let dicionario = json as? [CHHapticPattern.Key: Any] else { return nil }
            return try CHHapticPattern(dictionary: dicionario)
        } catch {
            print("Erro ao ler \(nome).ahap: \(error)")
            return nil
        }
    }

    // Toca um .ahap. "forca" muda a vibração e "volume" muda o som (os dois de 0 a 1).
    private func tocar(_ nome: String, forca: Float = 1, volume: Float = 1) {
        guard suportado, let player = players[nome] else { return }
        do {
            try ligarSePreciso()
            try player.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: forca, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .audioVolumeControl, value: volume, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Erro ao tocar \(nome): \(error)")
        }
    }

    // MARK: Momentos da vela

    func acender() { tocar("Acender") }

    func apagar() { tocar("Apagar") }

    func fim() { tocar("Fim") }

    // forca: 0 a 1 (vela grande = prego cai de mais alto = batida mais forte e som mais alto)
    func prego(forca: Float) {
        let f = max(0, min(1, forca))
        tocar("Prego", forca: 0.5 + 0.5 * f, volume: 0.4 + 0.6 * f)
    }

    // Batidinha leve ao trocar o tamanho da vela (é rápida, então fica no código mesmo)
    func tique() {
        guard suportado, let engine else { return }
        do {
            try ligarSePreciso()
            let evento = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ], relativeTime: 0)
            try engine.makePlayer(with: CHHapticPattern(events: [evento], parameters: []))
                .start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Erro no tique: \(error)")
        }
    }

    // Gota de cera batendo no prato ou na mesa (aba 3D): bem fraquinha e "seca"
    func pingo() {
        guard suportado, let engine else { return }
        do {
            try ligarSePreciso()
            let evento = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
            ], relativeTime: 0)
            try engine.makePlayer(with: CHHapticPattern(events: [evento], parameters: []))
                .start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Erro no pingo: \(error)")
        }
    }

    // MARK: Textura da chama (em loop)

    func iniciarChama() {
        guard suportado, let chama else { return }
        do {
            try ligarSePreciso()
            // Começa fraquinha, como no exemplo da Apple (a textura começa do zero e vai sendo ajustada)
            try chama.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.35, relativeTime: 0)
            ], atTime: 0)
            try chama.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Erro na chama: \(error)")
        }
    }

    // inclinacao: 0 (em pé) a 1 (bem inclinado). Mais inclinado = chama mais forte.
    func atualizarChama(inclinacao: Float) {
        guard suportado, let chama else { return }
        let forca = 0.35 + 0.45 * max(0, min(1, inclinacao))
        try? chama.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: forca, relativeTime: 0)
        ], atTime: 0)
    }

    func pararChama() {
        try? chama?.stop(atTime: CHHapticTimeImmediate)
    }
}

#Preview {
    ContentView()
}
