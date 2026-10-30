/**
 * A consulta contra Postgres real, com a tabela `clients` no formato que as
 * migrations da aplicacao criam (so as colunas que a funcao le).
 */
import { Pool } from 'pg';
import { GenericContainer, StartedTestContainer, Wait } from 'testcontainers';
import { findActiveClientId } from '../../functions/auth-cpf/client-lookup';

const ACTIVE = '11111111-1111-4111-8111-111111111111';

describe('findActiveClientId', () => {
  let container: StartedTestContainer;
  let pool: Pool;

  beforeAll(async () => {
    container = await new GenericContainer('postgres:16-alpine')
      .withEnvironment({ POSTGRES_PASSWORD: 'test', POSTGRES_DB: 'test' })
      .withExposedPorts(5432)
      .withWaitStrategy(Wait.forLogMessage(/database system is ready to accept connections/, 2))
      .start();
    pool = new Pool({
      host: container.getHost(),
      port: container.getMappedPort(5432),
      user: 'postgres',
      password: 'test',
      database: 'test',
    });
    await pool.query(`
      CREATE TABLE clients (
        id uuid PRIMARY KEY,
        cpf_cnpj varchar(14) NOT NULL,
        status varchar(10) NOT NULL DEFAULT 'ATIVO',
        deleted_at timestamp
      )`);
    await pool.query(`
      INSERT INTO clients (id, cpf_cnpj, status, deleted_at) VALUES
        ('${ACTIVE}', '52998224725', 'ATIVO', NULL),
        ('22222222-2222-4222-8222-222222222222', '11144477735', 'INATIVO', NULL),
        ('33333333-3333-4333-8333-333333333333', '39053344705', 'ATIVO', now())`);
  }, 120_000);

  afterAll(async () => {
    await pool?.end();
    await container?.stop();
  });

  it('encontra o cliente ativo pelo CPF', async () => {
    expect(await findActiveClientId(pool, '52998224725')).toBe(ACTIVE);
  });

  it.each([
    ['inativo', '11144477735'],
    ['excluido', '39053344705'],
    ['inexistente', '86288366757'],
  ])('nao encontra cliente %s', async (_caso, cpf) => {
    expect(await findActiveClientId(pool, cpf)).toBeNull();
  });
});
