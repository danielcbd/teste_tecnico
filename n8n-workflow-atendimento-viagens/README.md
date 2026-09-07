# Atendimento e Qualificação de Leads — Agência de Viagens (n8n + UAZAPI + Supabase)

Workflow de n8n para realizar o atendimento de leads de uma agência de viagens via WhatsApp
(UAZAPI), 24/7, com:

- **Debounce de 1 minuto**: mensagens picadas ("oi" + "tudo bem" + "queria saber sobre...") viram
  um único contexto antes da primeira resposta.
- **Memória persistente em banco (Supabase/Postgres)**: se o lead voltar dias depois, o agente
  carrega o histórico e responde como quem já conhece a conversa.
- **Detecção de assunto novo**: se o lead voltar falando de outra coisa, o workflow abre um novo
  "atendimento" em vez de misturar com o histórico antigo.
- **Qualificação frio / morno / quente** a cada atendimento, com notificação automática em um
  **grupo do WhatsApp**.
- **Handoff humano**: se você responder manualmente pelo WhatsApp, o agente se desativa para
  aquele lead e para de interagir.

## ⚠️ Sobre a integração com UAZAPI

Não consegui acessar a documentação oficial da UAZAPI a partir deste ambiente (o domínio
`uazapi.com` está bloqueado pela política de rede do sandbox onde montei este workflow). Os nodes
`Normalizar Payload UAZAPI`, `Enviar Resposta ao Lead (UAZAPI)` e `Notificar Grupo no WhatsApp
(UAZAPI)` foram montados seguindo o formato mais comum entre APIs de WhatsApp não-oficiais
baseadas em Baileys (mesma família da Evolution API), mas **os nomes de campo/endpoint podem não
bater exatamente com sua instância**. Antes de ativar:

1. Configure o webhook da sua instância UAZAPI apontando para a URL do node
   `Webhook UAZAPI (todas as mensagens)` e dispare uma mensagem de teste.
2. Abra a execução no n8n, veja o `body` que chegou de verdade e ajuste o node **Normalizar
   Payload UAZAPI** (campos `phone`, `text`, `fromMe`, `externalId`, `pushName`) para bater com o
   payload real.
3. Confirme no painel/docs da UAZAPI: o endpoint de envio de texto, o header de autenticação
   (assumi `token`) e o formato do ID de mensagem retornado — ajuste os nodes **Enviar Resposta ao
   Lead** e **Extrair ID da Mensagem Enviada**.
4. Pegue o **ID do grupo** do WhatsApp de destino (geralmente termina em `@g.us`) e substitua o
   placeholder `SEU_GROUP_ID@g.us` no node **Notificar Grupo no WhatsApp**.

Se puder me colar um exemplo real do payload do webhook e do endpoint de envio (ex.: do
Postman/curl que a UAZAPI fornece), eu ajusto esses três nodes com precisão.

## Como importar

1. Rode o `supabase-schema.sql` no **SQL Editor** do seu projeto Supabase (cria as tabelas
   `leads`, `atendimentos` e `mensagens`).
2. No n8n: **Workflows → Import from File** → `workflow.json` (fluxo principal) e, opcionalmente,
   `workflow-encerrar-atendimentos-inativos.json` (manutenção diária, ver seção 5).
3. Configure as credenciais:
   - **Postgres** (aponta pro Supabase — em *Project Settings → Database → Connection string* do
     Supabase, use a connection string de sessão/porta 5432 ou o pooler, conforme sua preferência).
   - **OpenAI** para o Chat Model do agente (ou troque pelo provedor de LLM que preferir).
4. Ajuste os nodes UAZAPI conforme a seção acima e ative o workflow.

## Como funciona

### 1. Um único webhook para tudo — e o problema do "eco do próprio bot"

A UAZAPI normalmente manda **todas** as mensagens da instância (recebidas do lead e enviadas por
você) para o mesmo webhook, marcando `fromMe = true` quando o número da agência é quem enviou.
Isso inclui as mensagens que o **próprio agente de IA** manda via API — se eu tratasse qualquer
`fromMe = true` como "atendente humano respondeu", o bot se desativaria sozinho a cada resposta
seguinte.

Solução: sempre que o bot envia uma mensagem (node `Enviar Resposta ao Lead`), o ID retornado pela
UAZAPI é salvo na tabela `mensagens.external_id`. Quando chega um evento `fromMe = true`, o
workflow verifica se aquele ID já está registrado como mensagem do `agente` (node **Verificar se é
Eco do Próprio Bot**):
- **Achou** → é só o eco da própria resposta da IA → não faz nada.
- **Não achou** → foi você digitando manualmente no WhatsApp → dispara o handoff (seção 4).

### 2. Debounce de 1 minuto (mensagens picadas viram contexto único)

O estado de fila fica na própria tabela `leads` (`waiting` + `fila_pendente`), com um `UPDATE ...
FOR UPDATE` atômico (node **Enfileirar Mensagem**) para evitar corrida quando várias mensagens
chegam quase juntas:

- Só a **primeira** mensagem de uma janela dispara o node **Wait** (60s); as seguintes só se
  empilham em `fila_pendente` e a execução termina ali.
- Ao final do Wait, o node **Coletar Fila e Limpar** lê tudo que se acumulou, junta num único texto
  e zera a fila — só então o Agente de IA é chamado, gerando **uma** resposta para as N mensagens
  picadas.

Por estar no banco (e não em memória do n8n), esse controle funciona mesmo com múltiplas instâncias
do n8n rodando em paralelo (worker mode).

### 3. Memória entre dias + detecção de assunto novo

Cada linha da tabela `atendimentos` representa uma "conversa/assunto" com um lead — um mesmo lead
(`leads`) pode ter vários atendimentos ao longo do tempo.

Quando a janela de 1 minuto fecha:

1. **Buscar Último Atendimento** — pega o atendimento mais recente desse lead (resumo,
   classificação, tópico, quando foi a última mensagem), não importa a idade.
2. **Preparar Contexto e Calcular Gap** — calcula quantas horas se passaram desde a última
   mensagem:
   - Menos de **6 horas** → é obviamente a mesma conversa, nem vale perguntar à IA (evita custo e
     risco de erro em conversas óbvias).
   - Mais de 6 horas (ex.: o exemplo de retornar 7 dias depois) → pede para o próprio Agente
     avaliar, com base no resumo anterior, se a mensagem nova é **continuação** ou um **assunto
     novo** (campo `mesmo_assunto` na saída estruturada).
3. **Decidir Atendimento** — combina os dois sinais acima:
   - Assunto novo (ou nenhum atendimento anterior) → cria uma **linha nova** em `atendimentos`,
     começando um histórico próprio (mas ainda vinculado ao mesmo lead).
   - Mesmo assunto → **atualiza** o atendimento existente (resumo cumulativo, reabre se estava
     encerrado, atualiza classificação).

O agente sempre recebe o resumo anterior (quando relevante) no prompt, então ele responde "como um
humano que lembra da conversa" quando é continuação, e como um primeiro atendimento normal quando
é assunto novo ou lead novo.

### 4. Qualificação do lead (frio / morno / quente) + aviso no grupo

O node **Qualificar Lead e Responder** retorna, além da resposta ao lead:

| Campo | Uso |
|---|---|
| `classificacao` | `frio`, `morno` ou `quente` |
| `topico` | rótulo curto do assunto (ex.: "Pacote Cancún - casal - julho") |
| `resumo_atendimento` | resumo cumulativo, salvo em `atendimentos.resumo` para uso futuro |
| `mesmo_assunto` | usado só internamente para decidir se reaproveita o atendimento |

Critérios de classificação usados no prompt:

| Classificação | Critério |
|---|---|
| **Quente** | Data definida/próxima, orçamento mencionado, urgência clara, ou pede para fechar/agendar |
| **Morno** | Interesse real com alguma informação (destino ou período), sem urgência ou dados completos |
| **Frio** | Mensagem vaga, curiosidade, sem intenção clara, ou ignora as perguntas de qualificação |

Depois de responder ao lead, o node **Notificar Grupo no WhatsApp** manda uma mensagem tipo:

> João Silva está QUENTE (Pacote Cancún - casal - julho)

para o grupo configurado, para o time comercial acompanhar sem precisar abrir o chat individual.

### 5. Desativação ao responder manualmente (handoff)

Coberto na seção 1 (detecção via `fromMe` + checagem de eco). Quando confirmado que foi você quem
respondeu manualmente, o node **Desativar Agente (Handoff Humano)** marca
`leads.agent_active = false` — a partir daí toda mensagem nova desse lead cai direto em **Fim -
Atendente Humano Está Cuidando**, sem nenhuma resposta automática.

Também é tratada a corrida em que você responde **durante** a janela de espera de 1 minuto: o node
**Coletar Fila e Limpar** reconfere `agent_active` logo após o Wait; se você já assumiu nesse
meio-tempo, o fluxo termina em **Fim - Humano Assumiu Durante Espera** sem enviar a resposta
automática.

> Reativar o agente para um lead não foi pedido, mas é trivial de adicionar: um novo webhook (ou
> comando tipo `/reativar` reconhecido no `Normalizar Payload`) que rode
> `UPDATE leads SET agent_active = true WHERE phone = $1`.

O segundo arquivo, `workflow-encerrar-atendimentos-inativos.json`, é uma manutenção diária (Cron às
3h) que só marca `atendimentos.status = 'encerrado'` para conversas paradas há mais de 48h — isso é
cosmético/organizacional (não afeta a lógica de continuidade, que usa o cálculo de horas
independente do `status`), mas ajuda a visualizar no Supabase quais atendimentos ainda estão em
aberto.

## Adaptações necessárias antes de ir para produção

- Confirmar e ajustar os campos/endpoints da UAZAPI (ver aviso no topo).
- Definir o ID do grupo do WhatsApp de destino das notificações.
- Definir a connection string do Postgres/Supabase na credencial do n8n.
- Opcional: ajustar o limite de 6h (`LIMITE_HORAS_MESMO_ASSUNTO`, no node **Preparar Contexto e
  Calcular Gap**) para o que fizer mais sentido no seu funil (ex.: 12h, 24h).
