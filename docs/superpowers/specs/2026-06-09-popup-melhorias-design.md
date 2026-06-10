# claude-usebar — 4 melhorias no popup (design aprovado)

Data: 2026-06-09 · Aprovado pelo usuário em conversa.

## Requisitos

1. **Responsividade total**: ao redimensionar o popup, todo o conteúdo (fontes, barras,
   espaçamentos, botão de fixar) escala proporcionalmente, sem corte nem sobra.
2. **Modelo em uso**: exibir o modelo Claude atualmente em uso na linha de título:
   `Claude · Team · Fable 5`.
3. **Countdown em tempo real**: linha no rodapé `atualiza em m:ss` contando até a próxima
   atualização de uso, atualizada a cada 1s **somente enquanto o popup está aberto**.
4. **Fundo Cruzeiro**: imagem (`cruzeiro_2.jpg`) cobrindo todo o popup em modo "cover",
   com véu escuro (~75%) por cima para legibilidade.

## Decisões de design

- **Escala**: fator `k = min(largura/330, altura/alturaBase)` calculado a cada pintura;
  todas as medidas multiplicam `k`. Barras continuam preenchendo a largura.
- **Fonte do modelo**: tail do `.jsonl` mais recente em `%USERPROFILE%\.claude\projects\`,
  último campo `"model"` de mensagem do assistant (ignora `<synthetic>`). ID → nome
  amigável via mapa (fallback: prettify do ID). Atualiza a cada ciclo de uso e ao abrir
  o popup. Sem modelo → título como hoje.
- **Countdown**: `$script:NextUpdateAt` mantido em todo (re)agendamento do timer principal
  (tick normal, backoff, atualizar agora). Timer de UI de 1s ligado no `Show-Popup`,
  desligado quando o popup some. Zerou → `atualizando…`.
- **Fundo**: chaves novas no config: `backgroundImage` e `backgroundDarken` (0.75).
  No primeiro run, se `Desktop\cruzeiro_2.jpg` existir e o config não tiver imagem,
  copia para `%LOCALAPPDATA%\claude-usebar\background.jpg` e aponta o config para lá.
  Bitmap carregado uma vez e cacheado; arquivo ausente → fundo sólido atual, sem erro.

## Erros e teste

- Cada feature degrada silenciosamente para o comportamento atual.
- Teste: `-Once` (detecção de modelo via stdout), `-Foreground` (visual), e checagem de
  sintaxe via parser do PowerShell.
