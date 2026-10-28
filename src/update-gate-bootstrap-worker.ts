import { parentPort, workerData } from "node:worker_threads";
import { bootstrapUpdateGate } from "./update-gate-bootstrap";

parentPort?.postMessage(bootstrapUpdateGate(workerData));
