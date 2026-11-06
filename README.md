# Testes da Vela 🕯️

Testes técnicos e estéticos do app do **Time Ada Lovelace** no Challenge 4 ("Out of the box") da Apple Developer Academy | PUC-Rio.

**A ideia do app:** um timer em que a contagem do tempo acontece pelo derretimento de uma vela. A luz dessa vela projeta imagens no estilo teatro de sombras, que é o encantamento do app.

## Os testes (uma aba para cada)

| Aba | Arquivo | O que testa |
| --- | --- | --- |
| **2D** | `ContentView.swift` (`VelaRealistaView`) | Vela desenhada em 2D, com luz, cera escorrendo e a sombra de um passarinho que cresce com o tempo |
| **3D** | `RealityVelaView.swift`, `CeraSimulacao.swift` e `CeraEntidades.swift` | A vela em 3D com RealityKit, com sombras de verdade na parede. A cera tem física: poça no topo sempre reta com o chão, pingos que escorrem e pingam para o lado contrário da chama, gotas que acumulam em montinhos no prato, na mesa e na parede, e a chama que derrete a borda em que encosta (e apaga se entrar na cera). No simulador, arrastar a vela inclina e dois toques endireitam |
| **Caixa** | `CaixaVelaView.swift` | A vela dentro de uma caixa com estrelas recortadas que gira devagar. O botão "Sair da caixa" leva a câmera para fora, pela janela da caixa, mostrando as estrelas de luz no quarto. A cera tem a mesma física da aba 3D: as gotas caem no fundo, nas paredes (e giram junto com a caixa) ou na tampa |

Todas as abas têm o mesmo timer:

- o **tamanho** da vela é o tempo (pequena, média ou grande), sem nenhum número na tela
- a vela **derrete** com o tempo
- um **prego** cai na metade, com som e vibração
- **virar o celular** de cabeça para baixo apaga a vela e pausa o tempo
- **inclinar** o celular faz a vela derreter mais rápido, e a chama continua apontando para cima
- o **fim** tem uma vibração forte que vai sumindo
- o **VoiceOver** descreve a vela com palavras, sem números

## Tecnologias

- **SwiftUI** e **RealityKit**
- **Core Motion**: inclinar e virar o celular
- **Core Haptics**: vibrações em arquivos `.ahap` com som junto, seguindo a sessão [Practice audio haptic design (WWDC21)](https://developer.apple.com/videos/play/wwdc21/10278/)

As vibrações e os sons ficam na pasta `SonsEVibracoes 2`. Os sons são provisórios.

## Como rodar

1. Abra o `TestesCoreMotion.xcodeproj` no Xcode.
2. Escolha o seu **Team** em *Signing & Capabilities*.
3. Rode num **iPhone de verdade** (iOS 18 ou mais novo). O simulador não vibra nem sente movimento.
