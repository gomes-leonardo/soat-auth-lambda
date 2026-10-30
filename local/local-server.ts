import { createServer, IncomingMessage } from 'http';
import { Pool } from 'pg';
import { createAuthCpf } from '../functions/auth-cpf/auth-cpf';
import { findActiveClientId } from '../functions/auth-cpf/client-lookup';
import { signClientToken } from '../functions/auth-cpf/token';
import { log } from '../functions/shared/http';

/**
 * Substituto local da Function URL, para o cluster Kind antes da ativacao da
 * AWS. Mesmo codigo de autenticacao, mesmo contrato HTTP; muda so de onde vem
 * a configuracao: dos Secrets soat-db e soat-jwt montados como variaveis.
 */
const pool = new Pool({
  host: requiredEnv('DB_HOST'),
  port: Number(process.env.DB_PORT || 5432),
  database: requiredEnv('DB_NAME'),
  user: requiredEnv('DB_USER'),
  password: requiredEnv('DB_PASS'),
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false,
  max: 2,
});
const jwtSecret = requiredEnv('JWT_SECRET');

const authCpf = createAuthCpf({
  findActiveClientId: (cpf) => findActiveClientId(pool, cpf),
  signToken: async (clientId) => signClientToken(clientId, jwtSecret),
});

const server = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' }).end('{"status":"ok"}');
    return;
  }
  if (req.method !== 'POST') {
    res.writeHead(405).end();
    return;
  }
  try {
    const result = await authCpf({
      body: await readBody(req),
      isBase64Encoded: false,
      headers: {},
    });
    res.writeHead(result.statusCode ?? 200, result.headers as Record<string, string>);
    res.end(result.body);
  } catch (err) {
    log('error', 'cpf auth failed', { err: String(err) });
    res.writeHead(500, { 'content-type': 'application/json' }).end('{"error":"internal_error"}');
  }
});

server.listen(Number(process.env.PORT || 8080), () => log('info', 'local auth server started'));

process.on('SIGTERM', () => server.close(() => pool.end().then(() => process.exit(0))));

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Variavel ${name} nao configurada`);
  return value;
}
