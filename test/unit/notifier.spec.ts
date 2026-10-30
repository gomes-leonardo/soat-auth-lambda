import { createNotifier } from '../../functions/notifier/notifier';
import { formatAlert } from '../../functions/notifier/format';

const SECRET = 'segredo-do-notifier';
const OPENED = {
  issueId: 'abc',
  title: 'API indisponivel',
  state: 'ACTIVATED',
  priority: 'CRITICAL',
  createdAt: Date.UTC(2026, 9, 29, 21, 0, 0), // 18:00 em Brasilia
  condition: 'httpcheck 2xx < 1 por 2 min',
  policy: 'SOAT prd',
  tags: { serviceOrderId: ['33333333-3333-4333-8333-333333333333'], trace_id: ['4bf92f'] },
  url: 'https://one.newrelic.com/alerts/abc',
};

describe('formatAlert', () => {
  it('monta o e-mail de alerta aberto com OS, trace_id e horario de Brasilia', () => {
    const email = formatAlert(OPENED, 'prd');

    expect(email.subject).toBe('[SOAT][prd][ABERTO] API indisponivel');
    expect(email.message).toContain('Condicao: httpcheck 2xx < 1 por 2 min');
    expect(email.message).toContain('Aberto em: 29/10/2026, 18:00:00 (Brasilia)');
    expect(email.message).toContain('Ordem de servico: 33333333-3333-4333-8333-333333333333');
    expect(email.message).toContain('trace_id: 4bf92f');
    expect(email.message).toContain('Detalhes: https://one.newrelic.com/alerts/abc');
  });

  it('marca o fechamento como RESOLVIDO e informa quando', () => {
    const email = formatAlert(
      { ...OPENED, state: 'CLOSED', closedAt: Date.UTC(2026, 9, 29, 21, 10, 0), tags: {} },
      'hml',
    );

    expect(email.subject).toBe('[SOAT][hml][RESOLVIDO] API indisponivel');
    expect(email.message).toContain('Resolvido em: 29/10/2026, 18:10:00 (Brasilia)');
    expect(email.message).not.toContain('Ordem de servico');
    expect(email.message).not.toContain('trace_id');
  });

  it('corta o assunto em 100 caracteres, o limite do SNS', () => {
    expect(formatAlert({ ...OPENED, title: 'x'.repeat(200) }, 'prd').subject).toHaveLength(100);
  });
});

describe('notifier', () => {
  const publish = jest.fn(async () => undefined);
  const notifier = createNotifier({
    environment: 'prd',
    webhookSecret: async () => SECRET,
    publish,
  });
  const call = (authorization: string | undefined, body: unknown = OPENED) =>
    notifier({
      body: JSON.stringify(body),
      isBase64Encoded: false,
      headers: authorization ? { authorization } : {},
    });

  beforeEach(() => publish.mockClear());

  it('publica o e-mail quando o segredo confere', async () => {
    const result = await call(`Bearer ${SECRET}`);

    expect(result.statusCode).toBe(202);
    expect(publish).toHaveBeenCalledWith(
      '[SOAT][prd][ABERTO] API indisponivel',
      expect.stringContaining('Estado: ABERTO'),
    );
  });

  it.each([
    ['sem credencial', undefined],
    ['segredo errado', 'Bearer outro-segredo'],
    ['prefixo do segredo', `Bearer ${SECRET.slice(0, 5)}`],
    ['sem o esquema Bearer', SECRET],
  ])('recusa %s com 401 e nao publica nada', async (_caso, authorization) => {
    const result = await call(authorization);

    expect(result.statusCode).toBe(401);
    expect(publish).not.toHaveBeenCalled();
  });

  it('recusa corpo invalido com 400, mesmo autenticado', async () => {
    const result = await notifier({
      body: 'nao e json',
      isBase64Encoded: false,
      headers: { authorization: `Bearer ${SECRET}` },
    });
    expect(result.statusCode).toBe(400);
    expect(publish).not.toHaveBeenCalled();
  });
});
