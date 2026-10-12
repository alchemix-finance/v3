import fs from "node:fs/promises";
import path from "node:path";

export async function loadState(filename) {
  try {
    const parsed = JSON.parse(await fs.readFile(filename, "utf8"));
    return {
      lastProcessedBlock: parsed.lastProcessedBlock ? BigInt(parsed.lastProcessedBlock) : null,
      pendingScan: Boolean(parsed.pendingScan),
    };
  } catch (error) {
    if (error.code === "ENOENT") return { lastProcessedBlock: null, pendingScan: false };
    throw error;
  }
}

export async function saveState(filename, state) {
  await fs.mkdir(path.dirname(filename), { recursive: true });
  const temporary = `${filename}.tmp`;
  const body = `${JSON.stringify(
    {
      lastProcessedBlock: state.lastProcessedBlock?.toString() ?? null,
      pendingScan: Boolean(state.pendingScan),
    },
    null,
    2,
  )}\n`;
  await fs.writeFile(temporary, body, { encoding: "utf8", mode: 0o600 });
  await fs.rename(temporary, filename);
}
