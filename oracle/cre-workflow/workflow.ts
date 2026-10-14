// CRE-Workflow: holt einmal pro Woche die US-Sterbezahlen der CDC und meldet sie an CreMortalityOracle:
// Tote der letzten 4 Wochen und Durchschnitt derselben 4 Wochen in den 3 Vorjahren (Regel in cdc.js).
// Jeder Chainlink-Knoten fragt data.cdc.gov selbst ab; gemeldet wird nur, wenn alle dasselbe
// Ergebnis haben (identische Übereinstimmung). Die Knoten signieren den Bericht gemeinsam, der
// Chainlink-Forwarder prüft die Signaturen und ruft onReport am Oracle-Contract auf.
import {
  consensusIdenticalAggregation,
  cre,
  getNetwork,
  type HTTPSendRequester,
  json,
  ok,
  prepareReportRequest,
  type Runtime,
  TxStatus,
} from "@chainlink/cre-sdk";
import { encodeAbiParameters } from "viem";
import { z } from "zod";
import { cdcUrl, dayOf, pickWindow, targetMilli } from "./cdc.js";

export const configSchema = z.object({
  schedule: z.string(),           // Cron mit Sekunden, z. B. "0 0 12 * * 1" = montags 12:00 UTC
  cdcBaseUrl: z.string(),
  chainSelectorName: z.string(),  // Base Sepolia: "ethereum-testnet-sepolia-base-1"
  isTestnet: z.boolean(),
  oracleAddress: z.string(),      // CreMortalityOracle
  gasLimit: z.string(),
});
export type Config = z.infer<typeof configSchema>;

// Läuft auf jedem Knoten einzeln. Rückgabe als Text, damit "identisch" exakt verglichen werden kann.
const fetchWeek = (sender: HTTPSendRequester, url: string, today: number): string => {
  const res = sender.sendRequest({ url, method: "GET", timeout: "9s" }).result();
  if (!ok(res)) throw new Error(`CDC request failed: ${res.statusCode}`);
  const w = pickWindow(json(res), today);
  return `${w.weekEnding},${w.recent},${w.baseline}`;
};

export const onCron = (runtime: Runtime<Config>): string => {
  const cfg = runtime.config;
  const today = dayOf(runtime.now().getTime());
  const url = cdcUrl(cfg.cdcBaseUrl, today);

  const agreed = new cre.capabilities.HTTPClient()
    .sendRequest(runtime, fetchWeek, consensusIdenticalAggregation<string>())(url, today)
    .result();
  const [weekEnding, recent, baseline] = agreed.split(",").map((v) => BigInt(v));
  runtime.log(
    `CDC: 4 Wochen bis ${new Date(Number(weekEnding) * 1000).toISOString().slice(0, 10)}: ${recent} Tote, ` +
      `Vorjahre ${baseline}, Ziel-Faktor ${targetMilli(Number(recent), Number(baseline))}`,
  );

  const payload = encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
    [weekEnding, recent, baseline],
  );
  const report = runtime.report(prepareReportRequest(payload)).result();

  const network = getNetwork({ chainFamily: "evm", chainSelectorName: cfg.chainSelectorName, isTestnet: cfg.isTestnet });
  if (!network) throw new Error(`unknown chain ${cfg.chainSelectorName}`);
  const reply = new cre.capabilities.EVMClient(network.chainSelector.selector)
    .writeReport(runtime, {
      receiver: cfg.oracleAddress,
      report,
      gasConfig: { gasLimit: cfg.gasLimit },
    })
    .result();
  if (reply.txStatus !== TxStatus.SUCCESS) throw new Error(`write failed: ${reply.errorMessage ?? reply.txStatus}`);
  return agreed;
};

export const initWorkflow = (config: Config) => {
  const cron = new cre.capabilities.CronCapability();
  return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)];
};

