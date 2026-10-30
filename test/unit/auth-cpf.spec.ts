import jwt from 'jsonwebtoken';
import { createAuthCpf } from '../../functions/auth-cpf/auth-cpf';
import { signClientToken } from '../../functions/auth-cpf/token';

const SECRET = 'segredo-de-teste';
const ACTIVE_CPF = '52998224725';
const CLIENT_ID = '11111111-1111-4111-8111-111111111111';

function event(body: unknown) {
  return { body: JSON.stringify(body), isBase64Encoded: false, headers: {} };
}

describe('autenticacao por CPF', () => {
  const findActiveClientId = jest.fn(async (cpf: string) =>
    cpf === ACTIVE_CPF ? CLIENT_ID : null,
  );
  const authCpf = createAuthCpf({
    findActiveClientId,
    signToken: async (clientId) => signClientToken(clientId, SECRET),
  });

  beforeEach(() => findActiveClientId.mockClear());

  it('devolve um JWT de cliente para CPF de cliente ativo, com ou sem mascara', async () => {
    const result = await authCpf(event({ cpf: '529.982.247-25' }));

    expect(result.statusCode).toBe(200);
    const body = JSON.parse(result.body as string);
    expect(body).toMatchObject({ token_type: 'Bearer', expires_in: 3600 });
    expect(jwt.verify(body.access_token, SECRET)).toMatchObject({
      sub: CLIENT_ID,
      role: 'client',
      iss: 'soat-auth-lambda',
    });
  });

  it('o token expira em uma hora', async () => {
    const result = await authCpf(event({ cpf: ACTIVE_CPF }));
    const claims = jwt.decode(JSON.parse(result.body as string).access_token) as {
      iat: number;
      exp: number;
    };
    expect(claims.exp - claims.iat).toBe(3600);
  });

  it.each([
    ['CPF invalido', { cpf: '529.982.247-24' }],
    ['sem CPF', {}],
  ])('responde 400 para %s, sem consultar o banco', async (_caso, body) => {
    const result = await authCpf(event(body));

    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body as string)).toEqual({ error: 'invalid_cpf' });
    expect(findActiveClientId).not.toHaveBeenCalled();
  });

  it('responde 400 para corpo que nao e JSON', async () => {
    const result = await authCpf({ body: 'cpf=123', isBase64Encoded: false, headers: {} });
    expect(result.statusCode).toBe(400);
  });

  it('aceita corpo em base64, como a Function URL entrega as vezes', async () => {
    const body = Buffer.from(JSON.stringify({ cpf: ACTIVE_CPF })).toString('base64');
    const result = await authCpf({ body, isBase64Encoded: true, headers: {} });
    expect(result.statusCode).toBe(200);
  });

  it('responde 401 identico para CPF valido sem cliente ativo', async () => {
    const result = await authCpf(event({ cpf: '111.444.777-35' }));

    expect(result.statusCode).toBe(401);
    expect(JSON.parse(result.body as string)).toEqual({ error: 'unauthorized' });
  });
});
