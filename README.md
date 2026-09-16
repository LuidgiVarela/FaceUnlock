<div align="center">
  <img src="Assets/AppIcon/FaceUnlock-logo.png" width="112" alt="Logo do FaceUnlock">

  <h1>FaceUnlock</h1>

  <p><strong>Desbloqueie seu Mac com um olhar.</strong></p>
  <p>Reconhecimento facial local para macOS, com câmera sob demanda e uma experiência silenciosa na barra de menus.</p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-111318?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 ou superior">
    <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-111318?style=flat-square&logo=apple&logoColor=white" alt="Otimizado para Apple Silicon">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/processing-local-37C978?style=flat-square&logo=shield&logoColor=white" alt="Processamento local">
    <img src="https://img.shields.io/badge/status-experimental-F4A340?style=flat-square" alt="Projeto experimental">
  </p>
</div>

<br>

<img src="docs/images/faceunlock-settings.png" width="100%" alt="Painel de configurações do FaceUnlock">

## Seu Mac, pronto quando você estiver

FaceUnlock transforma a tela bloqueada em um fluxo simples e natural. O app fica discreto na barra de menus, observa apenas o estado da sessão e inicia o reconhecimento quando o macOS entra na Lock Screen.

<div align="center">
  <strong>Lock Screen</strong>
  &nbsp;→&nbsp; câmera ativa
  &nbsp;→&nbsp; liveness
  &nbsp;→&nbsp; identidade confirmada
  &nbsp;→&nbsp; Mac desbloqueado
</div>

## Feito para desaparecer

Durante o uso normal, FaceUnlock permanece em idle: câmera desligada, reconhecimento parado e nenhum monitoramento visual contínuo. A câmera é ativada somente durante cadastro, teste ou autenticação na tela bloqueada, e é interrompida assim que o fluxo termina.

| | Experiência |
|---|---|
| **Câmera sob demanda** | Permanece desligada enquanto a sessão está desbloqueada. |
| **Reconhecimento local** | Detecção facial, landmarks e liveness são processados no próprio Mac. |
| **Liveness temporal** | A decisão considera múltiplos frames, piscada e movimento natural. |
| **Integração nativa** | Funciona em segundo plano como um app de menu bar para macOS. |

## Privacidade por arquitetura

Nenhum frame da câmera é enviado para servidores. O template facial permanece local no dispositivo e a senha do macOS fica exclusivamente no Keychain do sistema.

Após uma correspondência facial válida, FaceUnlock recupera a credencial do Keychain e a envia à Lock Screen nativa por eventos de teclado do macOS. O projeto não modifica `AuthorizationDB`, PAM, SIP, FileVault ou `loginwindow`.

## Tecnologia

<p align="center">
  <img src="https://img.shields.io/badge/Swift-AppKit-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift e AppKit">
  <img src="https://img.shields.io/badge/Vision-Face%20Landmarks-4D8DFF?style=for-the-badge&logo=apple&logoColor=white" alt="Vision Framework">
  <img src="https://img.shields.io/badge/AVFoundation-Camera-8B5CF6?style=for-the-badge&logo=apple&logoColor=white" alt="AVFoundation">
  <img src="https://img.shields.io/badge/Keychain-Credentials-37C978?style=for-the-badge&logo=apple&logoColor=white" alt="macOS Keychain">
</p>

`Vision` cuida da análise facial, `AVFoundation` controla a câmera integrada, `Security.framework` protege a credencial e `CoreGraphics` conclui o fluxo na tela nativa do macOS.

## Estado do projeto

FaceUnlock é um experimento funcional desenvolvido e validado em um MacBook Air M1. Não é um substituto oficial para Touch ID ou para os mecanismos biométricos da Apple, e ainda não é distribuído como produto pronto para usuários finais.

O código está público para estudo, evolução e auditoria. Considerações de segurança e dados locais estão documentadas em [SECURITY.md](SECURITY.md).

---

<div align="center">
  <sub>Projetado e desenvolvido por <a href="https://github.com/LuidgiVarela">Luidgi Varela</a>.</sub>
</div>
