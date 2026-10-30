import { normalizeCpf } from '../../functions/auth-cpf/cpf';

describe('normalizeCpf', () => {
  it.each([
    ['529.982.247-25', '52998224725'],
    ['52998224725', '52998224725'],
    ['111.444.777-35', '11144477735'],
  ])('aceita %s', (input, expected) => {
    expect(normalizeCpf(input)).toBe(expected);
  });

  it.each([
    ['digito verificador errado', '529.982.247-24'],
    ['digitos repetidos', '111.111.111-11'],
    ['curto', '5299822472'],
    ['com letras', '529.982.247-2a'],
    ['vazio', ''],
    ['nao e texto', 52998224725],
    ['ausente', undefined],
  ])('recusa %s', (_caso, input) => {
    expect(normalizeCpf(input)).toBeNull();
  });
});
