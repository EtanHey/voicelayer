import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

export function packageJsonPath(): string {
  return join(dirname(fileURLToPath(import.meta.url)), "..", "package.json");
}

export function readPackageVersion(path = packageJsonPath()): string {
  const parsed = JSON.parse(readFileSync(path, "utf-8")) as {
    version?: unknown;
  };
  if (typeof parsed.version !== "string" || parsed.version.length === 0) {
    throw new Error(`package.json is missing a string version: ${path}`);
  }
  return parsed.version;
}

export const PACKAGE_VERSION = readPackageVersion();
