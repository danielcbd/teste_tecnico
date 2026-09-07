-- Schema Supabase (Postgres) para o workflow de atendimento e qualificação de leads
-- Execute isso no SQL Editor do Supabase antes de ativar o workflow no n8n.

create extension if not exists "pgcrypto"; -- para gen_random_uuid()

-- Um lead = um número de WhatsApp. Guarda o estado de handoff humano
-- e a fila de mensagens da janela de debounce de 1 minuto.
create table leads (
  id uuid primary key default gen_random_uuid(),
  phone text unique not null,              -- número normalizado (ex.: 5511999999999)
  name text,
  agent_active boolean not null default true, -- false = atendente humano assumiu, bot não responde mais
  waiting boolean not null default false,     -- true = já existe uma execução aguardando a janela de 1min
  fila_pendente jsonb not null default '[]'::jsonb, -- mensagens picadas aguardando o fim da janela
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Um atendimento = uma "conversa/assunto" com o lead. Um lead pode ter
-- vários atendimentos ao longo do tempo (ex.: falou de Cancún em janeiro,
-- volta em julho perguntando sobre Europa -> novo atendimento).
create table atendimentos (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete cascade,
  status text not null default 'aberto' check (status in ('aberto','encerrado')),
  topico text,               -- rótulo curto do assunto (ex.: "Pacote Cancún - casal - julho")
  resumo text,                -- resumo cumulativo usado como memória entre janelas/dias
  classificacao text check (classificacao in ('frio','morno','quente')),
  started_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

-- Histórico de mensagens, vinculado ao atendimento (assunto) e ao lead.
create table mensagens (
  id uuid primary key default gen_random_uuid(),
  atendimento_id uuid not null references atendimentos(id) on delete cascade,
  lead_id uuid not null references leads(id) on delete cascade,
  remetente text not null check (remetente in ('lead','agente','humano')),
  conteudo text not null,
  external_id text,           -- ID da mensagem retornado pela UAZAPI (usado para detectar eco do próprio bot)
  created_at timestamptz not null default now()
);

create index idx_atendimentos_lead on atendimentos (lead_id, last_message_at desc);
create index idx_mensagens_atendimento on mensagens (atendimento_id, created_at);
create index idx_mensagens_external_id on mensagens (external_id) where external_id is not null;
