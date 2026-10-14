import { beforeEach, afterEach } from "bun:test";
import { __resetBinarySpawnForTests } from "../../resolve-binary";

// Production caches last for the process; each fixture owns its own resolver.
beforeEach(() => __resetBinarySpawnForTests());
afterEach(() => __resetBinarySpawnForTests());
