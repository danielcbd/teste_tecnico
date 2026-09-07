# Atendimento e Qualificação de Leads — Agência de Viagens (n8n)

Workflow de n8n (`workflow.json`) para realizar o **primeiro atendimento** de um lead de agência
de viagens via chat/WhatsApp, agrupar mensagens picadas em uma única janela de contexto, qualificar
o lead como **frio / morno / quente**, e se desativar automaticamente quando um atendente humano
responde manualmente.

## Como importar

1. No n8n: **Workflows → Import from File** → selecione `workflow.json`.
2. Configure as credenciais:
   - **OpenAI Chat Model**: credencial OpenAI (ou troque pelo provedor de LLM que preferir).
   - **Google Sheets** (opcional, usado só para registrar a classificação do lead): credencial
     OAuth2 e o ID da planilha em `Registrar Classificação do Lead`.
3. Ajuste o node **Enviar Resposta ao Lead** com a URL/credencial real da sua API de mensageria
   (WhatsApp Cloud API, Evolution API, Twilio, Chatwoot, etc.) — está com uma URL placeholder.
4. Ative o workflow. Ele expõe dois webhooks:
   - `POST /webhook/lead-message` — chamado quando o lead envia uma mensagem.
   - `POST /webhook/agent-message` — chamado quando **o atendente humano** envia uma mensagem
     manualmente pelo canal oficial (ex.: evento `fromMe` do WhatsApp, ou o próprio CRM/inbox
     disparando este webhook ao enviar uma resposta).

Corpo esperado em ambos os webhooks (adapte os nomes de campo à sua integração):

```json
{ "sessionId": "5511999999999", "message": "Oi, queria saber sobre pacotes para Cancún" }
```

## Como funciona

### 1. Debounce de 1 minuto (mensagens picadas viram contexto único)

Como o n8n não tem um node nativo de "debounce", a janela de 1 minuto é implementada com:

- **Static Data do workflow** (`$getWorkflowStaticData('global')`): um pequeno estado
  `sessions[sessionId] = { active, waiting, messages[] }` que persiste entre execuções.
- Cada mensagem recebida é empilhada em `messages[]`.
- Só a **primeira** mensagem de uma janela dispara o node **Wait** (60s); mensagens seguintes
  dentro da mesma janela apenas se acumulam e a execução termina ali (evitando disparar 4
  respostas para 4 mensagens picadas).
- Quando o Wait libera, o workflow lê todas as mensagens acumuladas, junta como um único
  contexto e limpa a fila — só então chama o Agente de IA e envia **uma** resposta.

> Essa abordagem usa apenas recursos nativos do n8n (Static Data + Wait), sem depender de Redis
> ou banco externo. Para ambientes com múltiplas instâncias/workers do n8n em paralelo, o ideal em
> produção é trocar o Static Data por uma store externa (Redis com `SET NX EX 60` + `RPUSH`, ou uma
> tabela Postgres), já que Static Data não é compartilhado entre workers. A lógica de negócio
> (uma janela, uma resposta) permanece igual — só muda onde o estado é lido/escrito.

### 2. Qualificação do lead (frio / morno / quente)

O node **Qualificar Lead e Responder** (AI Agent) recebe todo o contexto acumulado da janela,
conduz a conversa de forma consultiva (destino, período, número de pessoas, orçamento, urgência)
e retorna uma saída estruturada (`Formato de Saída`) com:

- `resposta`: mensagem a enviar de volta ao lead;
- `classificacao`: `frio`, `morno` ou `quente`;
- `resumo_qualificacao`: resumo do que foi entendido sobre o lead.

Critérios usados no prompt do agente:

| Classificação | Critério |
|---|---|
| **Quente** | Data definida/próxima, orçamento mencionado, urgência clara, ou pede para fechar/agendar |
| **Morno** | Interesse real com alguma informação (destino ou período), sem urgência ou dados completos |
| **Frio** | Mensagem vaga, curiosidade, sem intenção clara, ou ignora as perguntas de qualificação |

A resposta é enviada ao lead (`Enviar Resposta ao Lead`) e a classificação é registrada em uma
planilha (`Registrar Classificação do Lead`) para o time comercial priorizar o funil.

Uma memória de conversa por lead (`Memória da Conversa`, com `sessionKey = sessionId`) é usada
para que o agente mantenha contexto entre janelas, caso a conversa continue além do primeiro
atendimento.

### 3. Desativação ao responder manualmente

Quando o atendente humano responde a um lead pelo canal oficial, esse envio deve chamar o webhook
`/agent-message` (na prática, isso normalmente vem de um evento da própria plataforma de
mensageria — ex.: WhatsApp Cloud API/Evolution API emitindo um evento para mensagens `fromMe`, ou
o CRM/inbox de atendimento notificando o n8n ao enviar). O node **Desativar Agente para a Sessão**
marca `active = false` para aquele `sessionId` no Static Data.

A partir daí, toda nova mensagem do lead cai no node **Agente Ativo para esta Sessão?**, é
identificada como `active = false` e o fluxo termina em **Fim - Atendente Humano Está Cuidando**
sem gerar nenhuma resposta automática — o agente fica desativado para aquele lead até decisão em
contrário (reativação manual pode ser adicionada facilmente com um terceiro webhook/comando que
grave `active = true` novamente).

Também é tratada a corrida em que o humano responde **durante** a janela de espera de 1 minuto: o
node **Coletar Mensagens da Janela** reconfere `active` logo após o Wait e, se o humano já assumiu
nesse meio-tempo, o fluxo termina em **Fim - Humano Assumiu Durante Espera** sem enviar a resposta
automática do agente.

## Adaptações necessárias para produção

- Trocar a URL placeholder de `Enviar Resposta ao Lead` pela API real do canal (WhatsApp/Instagram/etc).
- Configurar o gatilho real de "mensagem enviada por humano" (`/agent-message`) de acordo com a
  plataforma de mensageria usada.
- Se o n8n rodar com múltiplos workers, substituir o Static Data por Redis/Postgres para o
  controle de fila e do flag `active` (ver observação na seção 1).
- Ajustar o schema de saída/planilha conforme o CRM já usado pela agência.
