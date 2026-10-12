export function parseUnits(value, decimals) {
  if (!/^\d+(\.\d+)?$/.test(value)) throw new Error(`Invalid decimal value: ${value}`);
  const [whole, fraction = ""] = value.split(".");
  if (fraction.length > decimals) throw new Error(`${value} has more than ${decimals} decimal places`);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt((fraction + "0".repeat(decimals)).slice(0, decimals));
}

export function formatUnits(value, decimals, precision = 4) {
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const scale = 10n ** BigInt(decimals);
  const whole = absolute / scale;
  const fraction = (absolute % scale).toString().padStart(decimals, "0").slice(0, precision).replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

export function ratioBps(numerator, denominator) {
  if (denominator === 0n) return 10_000n;
  return (numerator * 10_000n) / denominator;
}
