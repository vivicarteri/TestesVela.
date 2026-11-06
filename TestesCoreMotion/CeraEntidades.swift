//  CeraEntidades.swift
//  O desenho da cera em RealityKit, usado pelas abas 3D e Caixa.
//  Transforma o que a CeraSimulacao calcula em coisas na cena:
//  - o corpo da vela: o topo (mapa de alturas) + a parede, refeito quando o topo derrete;
//  - a poça: o plano "reto com o chão", recortado onde ele fica acima da cera;
//  - os rastros: cordões de cera na parede da vela (os quentes cor de âmbar, os que endureceram cor de cera);
//  - as gotas caindo (esticadas no sentido da queda) e os montinhos onde elas caíram.
//
//  Como usar: crie com a CeraSimulacao, ponha "raiz" na cena com o zero no centro da base da vela
//  e chame atualizar(brilho:) a cada quadro, depois de cera.passo(...).

import UIKit
import RealityKit

@MainActor
final class CeraEntidades {
    let raiz = Entity()
    let cera: CeraSimulacao

    private let vela: ModelEntity
    private let poca: ModelEntity
    private let rastrosFrios: ModelEntity   // pingos que já endureceram
    private let rastrosQuentes: ModelEntity // pingos escorrendo agora
    private var gotas: [ModelEntity] = []
    private var manchas: [ModelEntity] = []
    private let esfera = MeshResource.generateSphere(radius: 1)
    private let materialCera: SimpleMaterial
    private let materialQuente: SimpleMaterial
    private var versaoTopoDesenhada = -1
    private var versaoRastrosDesenhada = -1
    private var rastrosDesenhadosEm = Date.distantPast
    private var brilhoDaPoca: Float = -1

    init(cera: CeraSimulacao, corCera: UIColor, rugosidade: Float) {
        self.cera = cera

        // As malhas são feitas na mão, então desenhamos os dois lados de cada triângulo
        var fria = SimpleMaterial(color: corCera, roughness: .float(rugosidade), isMetallic: false)
        fria.faceCulling = .none
        materialCera = fria
        var quente = SimpleMaterial(color: UIColor(red: 0.99, green: 0.86, blue: 0.62, alpha: 1),
                                    roughness: 0.25, isMetallic: false)
        quente.faceCulling = .none
        materialQuente = quente

        vela = ModelEntity(mesh: .generateCylinder(height: 0.001, radius: cera.raio), materials: [materialCera])
        poca = ModelEntity(mesh: esfera, materials: [materialQuente])
        rastrosFrios = ModelEntity(mesh: esfera, materials: [materialCera])
        rastrosQuentes = ModelEntity(mesh: esfera, materials: [materialQuente])
        for e in [vela, poca, rastrosFrios, rastrosQuentes] { raiz.addChild(e) }
        poca.isEnabled = false
        rastrosFrios.isEnabled = false
        rastrosQuentes.isEnabled = false
    }

    // MARK: A cada quadro

    func atualizar(brilho: Float) {
        // Corpo da vela: só refaz quando o topo mudou
        if cera.versaoTopo != versaoTopoDesenhada, let malha = malhaDoCorpo() {
            versaoTopoDesenhada = cera.versaoTopo
            vela.model?.mesh = malha
        }

        // Poça: muda a cada quadro (ela acompanha a gravidade)
        if let malha = malhaDaPoca() {
            poca.model?.mesh = malha
            poca.isEnabled = true
            if abs(brilho - brilhoDaPoca) > 0.05 {
                brilhoDaPoca = brilho
                poca.model?.materials = [materialDaPoca(brilho)]
            }
        } else {
            poca.isEnabled = false
        }

        // Rastros que já endureceram: refaz só quando mudam (no máximo 5 vezes por segundo)
        let agora = Date()
        if cera.versaoRastros != versaoRastrosDesenhada && agora.timeIntervalSince(rastrosDesenhadosEm) > 0.2 {
            versaoRastrosDesenhada = cera.versaoRastros
            rastrosDesenhadosEm = agora
            var m = Malha()
            for r in cera.rastros { tubo(r, em: &m) }
            mostrar(m, em: rastrosFrios)
        }

        // Pingos escorrendo agora: a cada quadro
        var quentes = Malha()
        for pg in cera.pingos { tubo(pg.rastro, em: &quentes) }
        mostrar(quentes, em: rastrosQuentes)

        // Gotas caindo: esticadas no sentido em que caem
        separar(&gotas, cera.gotas.count, materialQuente)
        for (e, gt) in zip(gotas, cera.gotas) {
            let r = cbrt(3 * gt.massa / (4 * .pi))
            let velocidade = simd_length(gt.v)
            let estica = 1 + min(2.5, velocidade * 0.25)
            e.position = gt.p
            e.orientation = velocidade > 0.001 ? Self.girar(de: [0, 1, 0], para: gt.v / velocidade)
                                               : simd_quatf(angle: 0, axis: [0, 1, 0])
            e.scale = [r / estica.squareRoot(), r * estica, r / estica.squareRoot()]
        }

        // Montinhos de cera onde as gotas caíram
        separar(&manchas, cera.manchas.count, materialCera)
        for (e, mc) in zip(manchas, cera.manchas) {
            let r = mc.raio
            e.position = mc.p
            e.orientation = Self.girar(de: [0, 1, 0], para: mc.normal)
            e.scale = [r, r * 0.3, r]
        }
    }

    /// Giro que leva a direção "a" para a direção "b" (as duas com tamanho 1).
    static func girar(de a: SIMD3<Float>, para b: SIMD3<Float>) -> simd_quatf {
        if simd_dot(a, b) < -0.9999 { return simd_quatf(angle: .pi, axis: [0, 0, 1]) }
        return simd_quatf(from: a, to: b)
    }

    // MARK: Ajudantes

    private func mostrar(_ m: Malha, em entidade: ModelEntity) {
        if let malha = m.recurso() {
            entidade.model?.mesh = malha
            entidade.isEnabled = true
        } else {
            entidade.isEnabled = false
        }
    }

    // Garante "n" esferas ligadas (cria mais se precisar) e desliga as que sobram
    private func separar(_ lista: inout [ModelEntity], _ n: Int, _ material: SimpleMaterial) {
        while lista.count < n {
            let e = ModelEntity(mesh: esfera, materials: [material])
            raiz.addChild(e)
            lista.append(e)
        }
        for (i, e) in lista.enumerated() { e.isEnabled = i < n }
    }

    private func materialDaPoca(_ brilho: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.95, green: 0.62, blue: 0.28, alpha: 1))
        m.roughness = 0.08
        m.metallic = 0.0
        m.emissiveColor = .init(color: UIColor(red: 1, green: 0.55, blue: 0.2, alpha: 1))
        m.emissiveIntensity = 0.15 + 0.55 * brilho      // cera líquida brilha de leve com a chama
        m.blending = .transparent(opacity: .init(floatLiteral: 0.78))
        m.faceCulling = .none
        return m
    }

    // MARK: Malhas

    // Topo (o mapa de alturas em anéis e fatias) + parede lateral
    private func malhaDoCorpo() -> MeshResource? {
        let nr = CeraSimulacao.aneis, na = CeraSimulacao.fatias
        var m = Malha()

        for i in 0..<(nr * na) {
            m.v.append([cera.cx[i], cera.topo[i], cera.cz[i]])
            m.n.append(.zero)
        }
        for j in 0..<(nr - 1) {
            for k in 0..<na {
                let k2 = (k + 1) % na
                let a = UInt32(j * na + k), b = UInt32(j * na + k2)
                let c = UInt32((j + 1) * na + k2), d = UInt32((j + 1) * na + k)
                m.i += [a, c, d]
                if j > 0 { m.i += [a, b, c] }
            }
        }
        // Normais do topo: média das faces em volta de cada ponto
        for s in stride(from: 0, to: m.i.count, by: 3) {
            let a = Int(m.i[s]), b = Int(m.i[s + 1]), c = Int(m.i[s + 2])
            let face = simd_cross(m.v[b] - m.v[a], m.v[c] - m.v[a])
            m.n[a] += face; m.n[b] += face; m.n[c] += face
        }
        for i in m.n.indices {
            let l = simd_length(m.n[i])
            m.n[i] = l > 1e-12 ? m.n[i] / l : [0, 1, 0]
        }

        // Parede: de baixo até a borda (que pode estar cavada pela chama)
        let base = UInt32(m.v.count)
        for k in 0..<na {
            let i = (nr - 1) * na + k
            let normal = SIMD3<Float>(cera.cx[i], 0, cera.cz[i]) / cera.raio
            m.v.append([cera.cx[i], 0, cera.cz[i]]); m.n.append(normal)
            m.v.append([cera.cx[i], cera.topo[i], cera.cz[i]]); m.n.append(normal)
        }
        for k in 0..<na {
            let k2 = (k + 1) % na
            let b0 = base + UInt32(2 * k), t0 = b0 + 1
            let b1 = base + UInt32(2 * k2), t1 = b1 + 1
            m.i += [b0, t0, b1, t0, t1, b1]
        }
        return m.recurso()
    }

    // A poça: o plano "reto com o chão", recortado onde ele fica acima da cera
    private func malhaDaPoca() -> MeshResource? {
        guard cera.nivel != nil else { return nil }
        let nr = CeraSimulacao.aneis, na = CeraSimulacao.fatias
        let u = cera.cima
        var m = Malha()

        func ponto(_ i: Int) -> (p: SIMD3<Float>, d: Float) {
            let y = cera.alturaDaPoca(i) ?? cera.topo[i]
            return (SIMD3(cera.cx[i], y, cera.cz[i]) + u * 0.0002, y - cera.topo[i])
        }
        func triangulo(_ a: Int, _ b: Int, _ c: Int) {
            let pts = [ponto(a), ponto(b), ponto(c)]
            var saida: [SIMD3<Float>] = []
            for s in 0..<3 {
                let p = pts[s], q = pts[(s + 1) % 3]
                if p.d >= 0 { saida.append(p.p) }
                if (p.d >= 0) != (q.d >= 0) { saida.append(p.p + (q.p - p.p) * (p.d / (p.d - q.d))) }
            }
            guard saida.count >= 3 else { return }
            let base = UInt32(m.v.count)
            for p in saida { m.v.append(p); m.n.append(u) }
            for s in 1..<(saida.count - 1) { m.i += [base, base + UInt32(s), base + UInt32(s + 1)] }
        }
        for j in 0..<(nr - 1) {
            for k in 0..<na {
                let k2 = (k + 1) % na
                triangulo(j * na + k, (j + 1) * na + k2, (j + 1) * na + k)
                if j > 0 { triangulo(j * na + k, j * na + k2, (j + 1) * na + k2) }
            }
        }
        return m.recurso()
    }

    // Um rastro de cera na parede: um "cordão" meio achatado, fino no começo e com uma bolinha na ponta
    private func tubo(_ r: CeraSimulacao.Rastro, em m: inout Malha) {
        guard r.pontos.count >= 2 else { return }
        var pts: [SIMD3<Float>] = []
        var normais: [SIMD3<Float>] = []
        var larguras: [Float] = []
        for (s, q) in r.pontos.enumerated() {
            let n = SIMD3<Float>(cos(q.x), 0, sin(q.x))
            pts.append(n * cera.raio + SIMD3(0, q.y, 0))
            normais.append(n)
            larguras.append(r.larguras[s])
        }
        larguras[0] *= 0.5
        let ultimo = pts.count - 1
        larguras[ultimo] *= 1.35
        var dir = pts[ultimo] - pts[ultimo - 1]
        dir = simd_length(dir) > 1e-6 ? simd_normalize(dir) : [0, -1, 0]
        pts.append(pts[ultimo] + dir * (larguras[ultimo] * 0.55))
        normais.append(normais[ultimo])
        larguras.append(0.0004)

        let lados = 5
        let base = UInt32(m.v.count)
        for s in pts.indices {
            var t = pts[min(pts.count - 1, s + 1)] - pts[max(0, s - 1)]
            t = simd_length(t) > 1e-6 ? simd_normalize(t) : [0, -1, 0]
            var lado = simd_cross(t, normais[s])
            lado = simd_length(lado) > 1e-6 ? simd_normalize(lado) : [-normais[s].z, 0, normais[s].x]
            let a = larguras[s] / 2, b = larguras[s] * 0.42
            for f in 0..<lados {
                let fi = Float.pi * Float(f) / Float(lados - 1)
                let c = cos(fi), sn = sin(fi)
                m.v.append(pts[s] + lado * (a * c) + normais[s] * (b * sn - 0.0002))
                m.n.append(simd_normalize(lado * (c * b) + normais[s] * (sn * a) + normais[s] * 1e-7))
            }
        }
        for s in 0..<(pts.count - 1) {
            for f in 0..<(lados - 1) {
                let a0 = base + UInt32(s * lados + f), a1 = a0 + 1
                let b0 = a0 + UInt32(lados), b1 = b0 + 1
                m.i += [a0, b0, a1, a1, b0, b1]
            }
        }
    }
}

/// Pontos, normais e triângulos de uma malha feita na mão.
private struct Malha {
    var v: [SIMD3<Float>] = []
    var n: [SIMD3<Float>] = []
    var i: [UInt32] = []

    @MainActor func recurso() -> MeshResource? {
        guard !i.isEmpty else { return nil }
        var d = MeshDescriptor(name: "cera")
        d.positions = MeshBuffers.Positions(v)
        d.normals = MeshBuffers.Normals(n)
        d.primitives = .triangles(i)
        return try? MeshResource.generate(from: [d])
    }
}
