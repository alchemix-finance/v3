import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { loadState, saveState } from "../src/state.js";

test("persists the processed block and pending rescan flag", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "alchemist-keeper-"));
  const filename = path.join(directory, "state.json");

  try {
    assert.deepEqual(await loadState(filename), { lastProcessedBlock: null, pendingScan: false });

    await saveState(filename, { lastProcessedBlock: 123n, pendingScan: true });
    assert.deepEqual(await loadState(filename), { lastProcessedBlock: 123n, pendingScan: true });
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});
