//  CeraSimulacao.swift
//  A física da cera das abas 3D e Caixa: derreter, formar a poça, transbordar,
//  escorrer, pingar e acumular. Tudo em metros, do tamanho de uma vela de verdade (raio de 3,5 cm).
//
//  A ideia em poucas palavras:
//  - A CHAMA e a VELA são dois objetos. A chama sempre aponta para cima no mundo de verdade
//    (Core Motion). Onde ela chega perto da cera, a cera derrete: é a "destruição".
//    Se a chama entra na cera, ou o pavio afunda na poça (celular muito virado), ela é abafada e apaga: é a "colisão".
//  - O topo da vela é um mapa de alturas em anéis e fatias (como uma pizza). Ele desce com o tempo
//    (o timer) e com o calor a mais da chama quando ela inclina e encosta na borda.
//  - A cera derretida forma uma poça no topo. A superfície fica sempre reta em relação ao chão de verdade,
//    como água num copo. Quando não cabe mais, transborda pelo ponto mais baixo da borda.
//    Por onde um pingo passa, a borda ganha um "canal", e os próximos pingos tendem a sair por ali.
//  - O que transborda vira pingo: escorre pela parede da vela no sentido da gravidade (o contrário da chama),
//    esfria, endurece e deixa um rastro. Se a gravidade puxa o pingo para fora da parede, ele se solta,
//    cai e vira um montinho onde bater (prato, mesa, parede, chão da caixa...). Gotas que caem no mesmo lugar se juntam.
//  - O desenho de tudo isso na cena fica no CeraEntidades.swift.
//
//  Coordenadas: as mesmas da cena, só que com o zero no centro da base da vela (onde ela está apoiada).
//  x para a direita, y para cima (o eixo da vela), z para a câmera.

import Foundation
import simd

final class CeraSimulacao {
    typealias V3 = SIMD3<Float>

    // MARK: Peças

    /// Cera que escorreu e endureceu na parede da vela. Cada ponto é (ângulo na vela, altura).
    struct Rastro {
        var pontos: [SIMD2<Float>] = []
        var larguras: [Float] = []
    }

    /// Cera escorrendo pela parede da vela.
    struct Pingo {
        var angulo: Float
        var y: Float
        var massa: Float                  // volume, em m³ (um pingo típico tem 0,05 ml)
        var calor: Float = 1              // 1 = acabou de sair da poça, 0 = endureceu
        var semente: Float = .random(in: 0...100)
        var rastro = Rastro()

        var largura: Float { CeraSimulacao.largura(massa) }
    }

    /// Pingo que se soltou da vela e está caindo.
    struct Gota {
        var p: V3
        var v: V3
        var massa: Float
    }

    /// Gota que caiu e endureceu (no prato, na mesa ou na parede). Vai crescendo quando outras caem em cima.
    struct Mancha {
        var p: V3
        var normal: V3
        var massa: Float
        var raio: Float { cbrt(max(0, massa) / 0.63) }   // montinho achatado: a altura é 0,3 do raio
    }

    /// O que a cena manda a cada quadro.
    struct Entrada {
        var agora: Date
        var alturaCheia: Float            // altura da vela nova
        var alturaPavio: Float            // altura da vela agora (é o timer)
        var brilho: Float                 // 0 = apagada, 1 = chama inteira
        var acesa: Bool
        var gravidade: V3                 // gravidade de verdade, nas coordenadas da cena, tamanho 1
    }

    // MARK: Medidas

    static let aneis = 9                  // do centro (0) até a borda (8)
    static let fatias = 36
    static let massaTipica: Float = 5e-8  // 0,05 ml
    static func largura(_ massa: Float) -> Float { max(0.0015, min(0.006, 1.05 * cbrt(max(0, massa)))) }

    let raio: Float = 0.035

    /// Uma superfície onde as gotas batem e grudam (prato, mesa, parede, chão da caixa...).
    struct Superficie {
        var ponto: V3                     // um ponto da superfície
        var normal: V3                    // para onde ela "olha" (o lado de onde as gotas chegam)
        var raio: Float?                  // se tiver, é um disco (como o prato) com esse raio em volta do ponto
    }
    /// Onde as gotas podem cair. A cena preenche, e pode mudar a cada quadro (como as paredes da caixa girando).
    var superficies: [Superficie] = []
    /// Gotas que passam dessa distância da vela saíram da cena e somem.
    var limite: Float = 1.3

    let raios: [Float]                    // raio de cada anel
    let cx: [Float]                       // posição (x, z) de cada ponto do mapa: índice = anel * fatias + fatia
    let cz: [Float]
    private let areas: [Float]            // área de cada ponto, por anel

    // MARK: Estado

    private(set) var topo: [Float]                // altura da cera em cada ponto do mapa
    private(set) var alturaCheia: Float = 0
    private(set) var liquido: Float = 0           // volume de cera derretida na poça
    private(set) var nivel: Float?                // altura da superfície da poça, medida "para cima" no mundo
    private(set) var cima = V3(0, 1, 0)           // "para cima" do mundo, nas coordenadas da vela
    private(set) var gravidade = V3(0, -1, 0)
    private(set) var pingos: [Pingo] = []
    private(set) var rastros: [Rastro] = []
    private(set) var gotas: [Gota] = []
    private(set) var manchas: [Mancha] = []
    private(set) var abafamento: Float = 0        // 0 = chama livre, 1 = apagou encostada na cera

    /// Mudam quando o topo ou os rastros endurecidos mudam (para a cena só refazer a malha quando precisa).
    private(set) var versaoTopo = 0
    private(set) var versaoRastros = 0

    /// Fica true quando a chama encosta na cera (ou afunda na poça) por tempo demais. A tela apaga a vela.
    var apagouPorColisao = false
    /// Quantas gotas bateram em algum lugar desde a última vez que a tela olhou (para vibrar).
    var batidas = 0

    private var ultimaData: Date?
    private var tempo: Float = 0
    private var profundidade: Float = 0           // a bacia no topo vai se formando nos primeiros segundos
    private var entalhe: [Float]                  // o "canal" na borda, por fatia
    private var transbordo: Float = 0
    private var proximoPingo: Float = massaTipica
    private var espera: Float = 0                 // tempo até o próximo pingo poder sair

    private var nr: Int { Self.aneis }
    private var na: Int { Self.fatias }

    init() {
        let nr = Self.aneis, na = Self.fatias, r = Float(0.035)

        let raios = (0..<nr).map { r * Float($0) / Float(nr - 1) }
        var areas: [Float] = []
        for j in 0..<nr {
            let dentro = j == 0 ? 0 : (raios[j - 1] + raios[j]) / 2
            let fora = j == nr - 1 ? r : (raios[j] + raios[j + 1]) / 2
            areas.append(.pi * (fora * fora - dentro * dentro) / Float(na))
        }
        var cx: [Float] = [], cz: [Float] = []
        for j in 0..<nr {
            for k in 0..<na {
                let a = 2 * Float.pi * Float(k) / Float(na)
                cx.append(raios[j] * cos(a))
                cz.append(raios[j] * sin(a))
            }
        }
        self.raios = raios
        self.areas = areas
        self.cx = cx
        self.cz = cz
        topo = Array(repeating: 0, count: nr * na)
        entalhe = Array(repeating: 0, count: na)
    }

    func reiniciar(alturaCheia: Float) {
        self.alturaCheia = alturaCheia
        topo = Array(repeating: alturaCheia, count: nr * na)
        entalhe = Array(repeating: 0, count: na)
        profundidade = 0
        liquido = 0
        nivel = nil
        pingos = []
        rastros = []
        gotas = []
        manchas = []
        transbordo = 0
        abafamento = 0
        apagouPorColisao = false
        batidas = 0
        versaoTopo += 1
        versaoRastros += 1
    }

    // MARK: Consultas (a cena usa para desenhar)

    /// Altura do topo da cera num ponto (x, z) dentro da vela.
    func alturaEm(_ x: Float, _ z: Float) -> Float {
        let r = min(raio, (x * x + z * z).squareRoot())
        let fj = r / raio * Float(nr - 1)
        let j0 = min(nr - 2, Int(fj))
        let tj = fj - Float(j0)
        var a = atan2(z, x)
        if a < 0 { a += 2 * .pi }
        let fk = a / (2 * .pi) * Float(na)
        let k0 = Int(fk) % na, k1 = (k0 + 1) % na
        let tk = fk - fk.rounded(.down)
        let dentro = topo[j0 * na + k0] * (1 - tk) + topo[j0 * na + k1] * tk
        let fora = topo[(j0 + 1) * na + k0] * (1 - tk) + topo[(j0 + 1) * na + k1] * tk
        return dentro * (1 - tj) + fora * tj
    }

    /// Altura da borda da vela num ângulo.
    func alturaDaBorda(_ angulo: Float) -> Float {
        var a = angulo.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        let fk = a / (2 * .pi) * Float(na)
        let k0 = Int(fk) % na, k1 = (k0 + 1) % na
        let tk = fk - fk.rounded(.down)
        let borda = (nr - 1) * na
        return topo[borda + k0] * (1 - tk) + topo[borda + k1] * tk
    }

    /// Altura (no eixo da vela) da superfície da poça num ponto do mapa. Nil se não tem poça.
    func alturaDaPoca(_ i: Int) -> Float? {
        guard let nivel, cima.y > 0.15 else { return nil }
        return (nivel - cx[i] * cima.x - cz[i] * cima.z) / cima.y
    }

    /// Onde fica a ponta do pavio (é dali que a chama sai).
    func pivoDaChama(alturaPavio: Float) -> V3 { V3(0, alturaPavio + 0.009, 0) }

    // MARK: A cada quadro

    func passo(_ e: Entrada) {
        if e.alturaCheia != alturaCheia { reiniciar(alturaCheia: e.alturaCheia) }
        let dtTotal = Float(e.agora.timeIntervalSince(ultimaData ?? e.agora))
        ultimaData = e.agora
        guard dtTotal > 0 else { return }

        // Passos pequenos deixam a física estável mesmo se um quadro atrasar
        let dt = min(dtTotal, 0.1)
        let n = max(1, Int((dt * 60).rounded(.up)))
        for _ in 0..<n { subpasso(e, dt / Float(n)) }
    }

    private func subpasso(_ e: Entrada, _ dt: Float) {
        tempo += dt
        espera -= dt
        gravidade = simd_normalize(e.gravidade)
        cima = -gravidade
        let acesa = e.acesa && e.brilho > 0.05

        if acesa { derreter(e, dt) }
        atualizarPoca(e, dt, acesa: acesa)
        verificarChama(e, dt)
        moverPingos(dt, acesa: acesa)
        moverGotas(dt)
        derreterRastros()
    }

    // MARK: 1. A chama derrete a cera

    private func pontosDaChama(_ e: Entrada, para u: V3) -> (base: V3, meio: V3, ponta: V3) {
        let pivo = pivoDaChama(alturaPavio: e.alturaPavio)
        let b = e.brilho
        return (pivo + u * (0.004 * b), pivo + u * (0.014 * b), pivo + u * (0.027 * b))
    }

    // Calor num ponto: soma de três "fontes" na chama (base, meio e ponta). Cai rápido com a distância.
    private func calor(_ p: V3, _ c: (base: V3, meio: V3, ponta: V3)) -> Float {
        func fonte(_ q: V3, _ peso: Float) -> Float { peso / (1 + simd_length_squared(p - q) / 1.21e-4) }
        return fonte(c.base, 0.6) + fonte(c.meio, 1) + fonte(c.ponta, 0.7)
    }

    private func derreter(_ e: Entrada, _ dt: Float) {
        let chama = pontosDaChama(e, para: cima)
        let reta = pontosDaChama(e, para: V3(0, 1, 0))
        profundidade = min(1, profundidade + dt / 4)
        for k in 0..<na { entalhe[k] = max(0, entalhe[k] - dt * 0.0005) }

        var peloTempo: Float = 0
        var peloCalor: Float = 0
        for j in 0..<nr {
            let u = raios[j] / raio                       // 0 no centro, 1 na borda
            for k in 0..<na {
                let i = j * na + k
                let canal = j == nr - 1 ? entalhe[k] : (j == nr - 2 ? entalhe[k] * 0.5 : 0)
                // Formato natural: buraquinho no meio, borda mais alta (e o canal por onde os pingos saem)
                let equilibrio = e.alturaPavio - 0.003 * profundidade + 0.006 * profundidade * u * u - canal
                let piso = max(0.001, e.alturaPavio - 0.003 - 0.019 * u)   // até onde a chama consegue cavar
                var h = topo[i]

                // O timer: tudo desce junto com o pavio
                if h > equilibrio {
                    let novo = max(equilibrio, h - 0.03 * dt)
                    peloTempo += (h - novo) * areas[j]
                    h = novo
                }

                // A destruição: o calor a mais quando a chama inclina e chega perto da borda
                let p = V3(cx[i], h, cz[i])
                let extra = calor(p, chama) - calor(p, reta)
                if extra > 0.02 && h > piso {
                    let novo = max(piso, h - 0.032 * (extra - 0.02) * e.brilho * dt)
                    peloCalor += (h - novo) * areas[j]
                    h = novo
                }
                topo[i] = h
            }
        }

        // A chama queima quase toda a cera que derrete (é o combustível dela).
        // Sobra um pouco, que enche a poça. A cera que a chama "arranca" da borda vai quase toda para a poça.
        liquido += peloTempo * 0.1 + peloCalor * 0.9
        versaoTopo += 1
    }

    // MARK: 2. A poça no topo (sempre reta em relação ao chão de verdade)

    // "Altura no mundo" de um ponto do topo: quanto maior, mais alto ele está de verdade
    private func alturaNoMundo(_ i: Int) -> Float { cx[i] * cima.x + topo[i] * cima.y + cz[i] * cima.z }

    private func volume(nivel: Float) -> Float {
        var v: Float = 0
        for i in topo.indices {
            let d = (nivel - cx[i] * cima.x - cz[i] * cima.z) / cima.y - topo[i]
            if d > 0 { v += d * areas[i / na] }
        }
        return v
    }

    private var inclinacao: Float { min(1, max(0, 1 - cima.y)) }

    private func atualizarPoca(_ e: Entrada, _ dt: Float, acesa: Bool) {
        // Sem chama, a poça esfria e endurece
        if !acesa { liquido -= liquido * dt / 3 }
        guard liquido > 1e-9 else { liquido = max(0, liquido); nivel = nil; return }

        // O ponto mais baixo da borda (no mundo)
        let borda = (nr - 1) * na
        var limite = Float.greatestFiniteMagnitude
        var fatiaBaixa = 0
        for k in 0..<na where alturaNoMundo(borda + k) < limite {
            limite = alturaNoMundo(borda + k)
            fatiaBaixa = k
        }

        // Vela muito deitada ou de cabeça para baixo: não segura nada, a poça derrama toda
        if cima.y < 0.15 {
            let derrama = min(liquido, max(4e-6, liquido * 2) * dt)
            liquido -= derrama
            nivel = nil
            transbordar(derrama, fatia: fatiaBaixa, fracao: 1)
            return
        }

        let capacidade = volume(nivel: limite)
        if liquido > capacidade {
            // Não cabe: transborda pelo ponto mais baixo da borda (se tem vários quase iguais, sorteia)
            var candidatas: [Int] = []
            for k in 0..<na where alturaNoMundo(borda + k) < limite + 0.0003 { candidatas.append(k) }
            transbordar(liquido - capacidade, fatia: candidatas.randomElement() ?? fatiaBaixa,
                        fracao: 0.06 + 2.5 * inclinacao)
            liquido = capacidade
            nivel = limite
        } else {
            // Procura a altura da superfície que guarda exatamente essa quantidade de cera
            var baixo = Float.greatestFiniteMagnitude
            for i in topo.indices { baixo = min(baixo, alturaNoMundo(i)) }
            var alto = limite
            for _ in 0..<14 {
                let meio = (baixo + alto) / 2
                if volume(nivel: meio) < liquido { baixo = meio } else { alto = meio }
            }
            nivel = (baixo + alto) / 2
        }
    }

    // Em pé, a chama queima quase todo o excesso e só um pouco escorre.
    // Inclinada, a poça derrama de verdade (fracao maior) e os pingos saem mais seguido.
    private func transbordar(_ quantidade: Float, fatia: Int, fracao: Float) {
        transbordo = min(transbordo + quantidade * min(1, fracao), Self.massaTipica * 6)
        while transbordo >= proximoPingo && espera <= 0 {
            soltarPingo(massa: proximoPingo, fatia: fatia)
            transbordo -= proximoPingo
            proximoPingo = Self.massaTipica * .random(in: 0.6...1.4)
            espera = 1 / (1.5 + 10 * inclinacao)
        }
    }

    private func soltarPingo(massa: Float, fatia k: Int) {
        let a = 2 * Float.pi * (Float(k) + .random(in: -0.35...0.35)) / Float(na)
        let n = V3(cos(a), 0, sin(a))
        let y = alturaDaBorda(a) - 0.0008
        let paraFora = simd_dot(gravidade, n)

        // A cera quente amolece a borda por onde passa: vira um canal, e os próximos pingos saem por ali
        entalhe[k] = min(0.0012, entalhe[k] + 0.00035)
        entalhe[(k + 1) % na] = min(0.0012, entalhe[(k + 1) % na] + 0.00015)
        entalhe[(k + na - 1) % na] = min(0.0012, entalhe[(k + na - 1) % na] + 0.00015)

        if cima.y < 0.15 || paraFora > 0.55 {
            // Derramando: a cera nem encosta na parede, cai direto
            gotas.append(Gota(p: n * (raio + 0.002) + V3(0, y + 0.001, 0),
                              v: gravidade * 0.15 + n * 0.08,
                              massa: massa))
        } else {
            pingos.append(Pingo(angulo: a, y: y, massa: massa))
        }
    }

    // MARK: 3. Colisão: a chama encostando na cera

    private func verificarChama(_ e: Entrada, _ dt: Float) {
        guard e.acesa else { abafamento = max(0, abafamento - dt * 3); return }
        let chama = pontosDaChama(e, para: cima)

        func dentroDaCera(_ q: V3) -> Bool {
            (q.x * q.x + q.z * q.z).squareRoot() < raio - 0.0005 && q.y > 0 && q.y < alturaEm(q.x, q.z) - 0.0008
        }

        var encostou: Float = 0
        if dentroDaCera(chama.meio) { encostou += 1 }
        if dentroDaCera(chama.ponta) { encostou += 0.5 }
        // Pavio afundado na cera derretida: a chama afoga
        if let nivel, simd_dot(pivoDaChama(alturaPavio: e.alturaPavio), cima) < nivel - 0.001 { encostou += 1 }

        if encostou > 0 {
            abafamento += encostou * dt / 0.5
        } else {
            abafamento = max(0, abafamento - dt * 2)
        }
        if abafamento >= 1 {
            apagouPorColisao = true
            abafamento = 0
        }
    }

    // MARK: 4. Pingos escorrendo pela parede

    private func moverPingos(_ dt: Float, acesa: Bool) {
        var i = 0
        while i < pingos.count {
            var pg = pingos[i]
            let n = V3(cos(pg.angulo), 0, sin(pg.angulo))           // para fora da parede
            let lado = V3(-sin(pg.angulo), 0, cos(pg.angulo))       // em volta da vela
            let gLado = simd_dot(gravidade, lado)
            let gCima = gravidade.y
            let paraFora = simd_dot(gravidade, n)

            // Cera quente escorre rápido; fria, quase não anda. Pingo maior desce mais rápido.
            let fluidez = pg.calor * pg.calor
            let velocidade = 0.06 * fluidez * (pg.massa / Self.massaTipica).squareRoot()
            // Um zigue-zague leve, como a cera de verdade
            let zigue = sin(tempo * 2.3 + pg.semente) * 0.22
            let andaLado = (gLado - gCima * zigue) * velocidade * dt
            let andaCima = (gCima + gLado * zigue) * velocidade * dt

            pg.angulo += andaLado / raio
            pg.y += andaCima
            let andou = (andaLado * andaLado + andaCima * andaCima).squareRoot()
            pg.massa = max(0, pg.massa - andou * 7e-7)           // vai deixando cera pelo caminho
            pg.calor -= dt / (acesa ? 3 : 2)                      // e vai esfriando
            marcar(&pg)

            var acabou = false
            if pg.y <= 0.0005 {
                // Chegou na base: a cera se espalha no prato, encostada na vela
                let p = n * (raio + pg.largura * 0.5)
                juntar(Mancha(p: V3(p.x, 0, p.z), normal: V3(0, 1, 0), massa: pg.massa))
                acabou = true
            } else if paraFora * cbrt(max(0, pg.massa) / Self.massaTipica) > 0.3 {
                // A gravidade puxa o pingo para fora da parede (lado de baixo da vela inclinada): ele se solta
                soltar(pg, n)
                acabou = true
            } else if pg.y > alturaDaBorda(pg.angulo) + 0.0005 {
                // A gravidade levou o pingo de volta ao topo (celular virando)
                if acesa && pg.calor > 0.4 { liquido += pg.massa } else { soltar(pg, n) }
                acabou = true
            } else if pg.calor <= 0.03 || pg.massa < Self.massaTipica * 0.08 {
                acabou = true    // endureceu
            }

            if acabou {
                if pg.rastro.pontos.count >= 2 {
                    rastros.append(pg.rastro)
                    if rastros.count > 40 { rastros.removeFirst(rastros.count - 40) }
                    versaoRastros += 1
                }
                pingos.remove(at: i)
            } else {
                pingos[i] = pg
                i += 1
            }
        }
    }

    // O rastro guarda pontos fixos a cada 2,5 mm, e o último ponto é a "cabeça" que acompanha o pingo
    private func marcar(_ pg: inout Pingo) {
        let atual = SIMD2(pg.angulo, pg.y)
        let n = pg.rastro.pontos.count
        if n >= 2 {
            let fixo = pg.rastro.pontos[n - 2]
            let d = SIMD2((fixo.x - atual.x) * raio, fixo.y - atual.y)
            if simd_length(d) < 0.0025 {
                pg.rastro.pontos[n - 1] = atual
                pg.rastro.larguras[n - 1] = pg.largura
                return
            }
        }
        pg.rastro.pontos.append(atual)
        pg.rastro.larguras.append(pg.largura)
    }

    private func soltar(_ pg: Pingo, _ n: V3) {
        gotas.append(Gota(p: n * (raio + pg.largura * 0.5) + V3(0, pg.y, 0),
                          v: gravidade * 0.05,
                          massa: pg.massa))
    }

    // MARK: 5. Gotas caindo

    private func moverGotas(_ dt: Float) {
        var i = 0
        while i < gotas.count {
            var gt = gotas[i]
            gt.v += gravidade * (9.8 * dt)
            gt.v *= 1 - 0.3 * dt
            gt.p += gt.v * dt
            let r = (gt.p.x * gt.p.x + gt.p.z * gt.p.z).squareRoot()

            var acabou = true
            if r < raio && gt.p.y > 0 && gt.p.y < alturaEm(gt.p.x, gt.p.z) - 0.0005 {
                // Bateu na vela: se caiu no topo, volta para a poça; se bateu na parede, gruda e escorre
                if r < raio - 0.003 && gt.p.y > alturaEm(gt.p.x, gt.p.z) - 0.004 {
                    liquido += gt.massa
                } else {
                    pingos.append(Pingo(angulo: atan2(gt.p.z, gt.p.x), y: gt.p.y, massa: gt.massa, calor: 0.6))
                }
            } else if let batida = superficieAtingida(gt) {
                pousar(gt, em: batida.ponto, normal: batida.normal)     // no prato, na mesa, na parede...
            } else if simd_length(gt.p) > limite {
                // saiu da cena
            } else {
                acabou = false
            }

            if acabou { gotas.remove(at: i) } else { gotas[i] = gt; i += 1 }
        }
    }

    // A gota passou para o outro lado de alguma superfície, indo na direção dela?
    private func superficieAtingida(_ gt: Gota) -> (ponto: V3, normal: V3)? {
        for s in superficies {
            let d = simd_dot(gt.p - s.ponto, s.normal)
            guard d <= 0, simd_dot(gt.v, s.normal) < 0 else { continue }
            let ponto = gt.p - s.normal * d
            if let raioDoDisco = s.raio {
                // Disco (prato): só conta se caiu dentro dele, e não muito abaixo
                guard d > -0.01, simd_length(ponto - s.ponto) <= raioDoDisco else { continue }
            }
            return (ponto, s.normal)
        }
        return nil
    }

    /// A caixa gira em volta da vela: os montinhos grudados nas paredes giram junto com elas.
    func girarManchasNasParedes(_ angulo: Float) {
        guard angulo != 0 else { return }
        let giro = simd_quatf(angle: angulo, axis: V3(0, 1, 0))
        for i in manchas.indices where abs(manchas[i].normal.y) < 0.5 {
            manchas[i].p = giro.act(manchas[i].p)
            manchas[i].normal = giro.act(manchas[i].normal)
        }
    }

    private func pousar(_ gt: Gota, em p: V3, normal: V3) {
        batidas += 1
        juntar(Mancha(p: p, normal: normal, massa: gt.massa))
    }

    // Caiu em cima de outra mancha: as duas viram uma só (a cera vai acumulando num montinho)
    private func juntar(_ nova: Mancha) {
        if let j = manchas.firstIndex(where: {
            simd_dot($0.normal, nova.normal) > 0.9 && simd_distance($0.p, nova.p) < $0.raio + nova.raio * 0.6
        }) {
            let total = manchas[j].massa + nova.massa
            let peso = nova.massa / max(1e-12, total)
            manchas[j].p += (nova.p - manchas[j].p) * peso      // o centro vai um pouco para onde a nova caiu
            manchas[j].massa = total
        } else {
            manchas.append(nova)
            if manchas.count > 60 { manchas.removeFirst() }
        }
    }

    // MARK: 6. O topo da vela vai descendo e derretendo os rastros antigos

    private func derreterRastros() {
        func cortar(_ r: inout Rastro) -> Bool {
            var cortou = false
            while let p = r.pontos.first, p.y > alturaDaBorda(p.x) + 0.0005 {
                r.pontos.removeFirst()
                r.larguras.removeFirst()
                cortou = true
            }
            return cortou
        }
        var mudou = false
        for i in rastros.indices where cortar(&rastros[i]) { mudou = true }
        if mudou {
            rastros.removeAll { $0.pontos.count < 2 }
            versaoRastros += 1
        }
        for i in pingos.indices { _ = cortar(&pingos[i].rastro) }
    }
}
