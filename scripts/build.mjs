import { build } from 'esbuild';

/**
 * Um bundle por funcao, com as dependencias embutidas: o zip da Lambda nao
 * precisa de node_modules. O SDK v3 da AWS ja vem no runtime nodejs22.x e fica
 * de fora.
 */
const common = {
  bundle: true,
  platform: 'node',
  target: 'node22',
  sourcemap: true,
  logLevel: 'info',
};

await build({
  ...common,
  entryPoints: {
    'auth-cpf/index': 'functions/auth-cpf/handler.ts',
    'notifier/index': 'functions/notifier/handler.ts',
  },
  outdir: 'dist',
  external: ['@aws-sdk/*'],
});

await build({
  ...common,
  entryPoints: { 'local-server': 'local/local-server.ts' },
  outdir: 'dist',
});
