/**
 * Validacao de CPF pelos digitos verificadores. Aceita com ou sem mascara e
 * devolve so os 11 digitos, ou `null` quando o CPF e invalido.
 */
export function normalizeCpf(input: unknown): string | null {
  if (typeof input !== 'string') return null;
  const digits = input.replace(/[.\-\s]/g, '');
  if (!/^\d{11}$/.test(digits)) return null;
  // 000.000.000-00, 111.111.111-11... passam no calculo, mas nao sao CPFs.
  if (/^(\d)\1{10}$/.test(digits)) return null;

  const numbers = digits.split('').map(Number);
  if (checkDigit(numbers.slice(0, 9)) !== numbers[9]) return null;
  if (checkDigit(numbers.slice(0, 10)) !== numbers[10]) return null;
  return digits;
}

function checkDigit(numbers: number[]): number {
  const weightStart = numbers.length + 1;
  const sum = numbers.reduce((acc, n, i) => acc + n * (weightStart - i), 0);
  const rest = (sum * 10) % 11;
  return rest === 10 ? 0 : rest;
}
