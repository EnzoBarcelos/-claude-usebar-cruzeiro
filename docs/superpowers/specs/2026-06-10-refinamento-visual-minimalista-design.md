# Design — Refinamento visual minimalista do claude-usebar

**Data:** 2026-06-10
**Objetivo:** deixar o widget mais limpo/minimalista mudando ícones, fonte e borda, mantendo
compatibilidade com Windows 10 e sem instalar fontes externas (importante para a distribuição
aos colegas).

## Decisões

| Tema | Decisão |
|---|---|
| Fonte do popup | `Segoe UI Variable` (Win11) com fallback para `Segoe UI` (Win10) |
| Cantos da janela | Arredondados, raio médio (~14px) |
| Borda | Linha fina translúcida de 1px (branco a ~16% alpha) |
| Ícone da bandeja | Só o número, sem fundo, na cor da severidade + halo escuro fino |
| Botão de fixar | `Segoe Fluent Icons` (traço mais leve, Win11) → `Segoe MDL2 Assets` (Win10) |

## Implementação (claude-usebar.ps1)

- **Região UI-Fonts (nova):** `Resolve-Fonts` testa as famílias via `[System.Drawing.FontFamily]`
  (que lança se ausente) e define `$script:UiFontFamily` e `$script:IconGlyphFamily` com fallback.
  Helper `New-UiFont` cria todas as fontes do popup. `Lighten-Color` clareia uma cor em direção
  ao branco. `$script:PopupCornerRadius = 14`.
- **`Set-TrayIcon`:** removido o fundo arredondado. O número é montado como `GraphicsPath`
  (`AddString`), contornado por um halo escuro translúcido (legibilidade em barras claras/escuras)
  e preenchido na cor recebida. Assinatura passou a `(-Text, -Color)`.
- **`Render`:** a cor de severidade/estado (`$IconBg`) agora é clareada 35% via `Lighten-Color`
  e passada como cor do número (as cores originais eram escuras, feitas para fundo).
- **`Draw-PopupContent`:** fontes via `New-UiFont`; ao final, desenha a borda fina arredondada
  (mesmo raio do recorte) anti-aliased, que também disfarça o serrilhado do `Region`.
- **`Set-PopupRegion` (nova):** aplica recorte arredondado à janela; chamada em `Show-Popup` e no
  evento `Resize`.
- **`Set-PinButtonLayout` / criação do pin:** fonte do glifo via `$script:IconGlyphFamily`; margem
  do alfinete aumentada para não ser cortada pelo canto arredondado.

## Compatibilidade

`Resolve-Fonts` garante degradação suave no Win10 (Segoe UI + Segoe MDL2 Assets). Os glifos do pin
(`0xE718`/`0xE77A`) existem nas duas famílias. Nenhuma fonte externa é instalada.

## Verificação

- Parser do PowerShell sem erros.
- Famílias resolvidas na máquina do autor: `Segoe UI Variable Text` e `Segoe Fluent Icons`.
- Widget reiniciado sem erro (renderiza o ícone no startup). Popup conferido visualmente ao clicar
  no ícone da bandeja: cantos arredondados, borda fina, fonte Variable, pin mais fino.
