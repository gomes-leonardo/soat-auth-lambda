export interface AlertPayload {
  issueId?: string;
  title?: string;
  state?: string;
  priority?: string;
  createdAt?: number | string;
  closedAt?: number | string | null;
  policy?: string;
  condition?: string;
  tags?: Record<string, unknown>;
  url?: string;
}

export interface Email {
  subject: string;
  message: string;
}

const STATE_LABEL: Record<string, string> = {
  ACTIVATED: 'ABERTO',
  CREATED: 'ABERTO',
  CLOSED: 'RESOLVIDO',
  ACKNOWLEDGED: 'RECONHECIDO',
};

/** O SNS recusa assunto de e-mail com mais de 100 caracteres. */
const SUBJECT_MAX = 100;

/**
 * Transforma o payload do workflow de alertas num e-mail que se le sem abrir
 * o New Relic: o que disparou, quando (horario de Brasilia), e por onde
 * comecar a investigar (a OS ou o trace_id, quando o alerta os carrega).
 */
export function formatAlert(payload: AlertPayload, environment: string): Email {
  const state = STATE_LABEL[payload.state ?? ''] ?? payload.state ?? 'ALERTA';
  const title = payload.title ?? 'Alerta sem titulo';
  const subject = `[SOAT][${environment}][${state}] ${title}`.slice(0, SUBJECT_MAX);

  const tags = payload.tags ?? {};
  const lines = [
    `Estado: ${state}`,
    `Alerta: ${title}`,
    payload.condition ? `Condicao: ${payload.condition}` : null,
    payload.policy ? `Politica: ${payload.policy}` : null,
    payload.priority ? `Prioridade: ${payload.priority}` : null,
    `Aberto em: ${brasilia(payload.createdAt)}`,
    state === 'RESOLVIDO' ? `Resolvido em: ${brasilia(payload.closedAt)}` : null,
    tag(tags, 'serviceOrderId') ? `Ordem de servico: ${tag(tags, 'serviceOrderId')}` : null,
    tag(tags, 'trace_id') ? `trace_id: ${tag(tags, 'trace_id')}` : null,
    payload.url ? `Detalhes: ${payload.url}` : null,
  ];

  return { subject, message: lines.filter((line) => line !== null).join('\n') };
}

/** O New Relic manda tags como lista de valores; usa o primeiro. */
function tag(tags: Record<string, unknown>, key: string): string | undefined {
  const value = tags[key];
  const first = Array.isArray(value) ? value[0] : value;
  return typeof first === 'string' && first.length > 0 ? first : undefined;
}

function brasilia(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return 'nao informado';
  const date = new Date(typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : value);
  if (Number.isNaN(date.getTime())) return 'nao informado';
  return `${new Intl.DateTimeFormat('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    dateStyle: 'short',
    timeStyle: 'medium',
  }).format(date)} (Brasilia)`;
}
