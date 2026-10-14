// Prüft den Workflow mit nachgebauter CDC und Chain: `bun test` in diesem Ordner.
import { describe, expect } from "bun:test";
import { EvmMock, HttpActionsMock, newTestRuntime, test } from "@chainlink/cre-sdk/test";
import { decodeAbiParameters, type Hex } from "viem";
import { type Config, onCron } from "./workflow";

const CONFIG: Config = {
  schedule: "0 0 12 * * 1",
  cdcBaseUrl: "https://data.cdc.gov/resource/r8kw-7aab.json",
  chainSelectorName: "ethereum-testnet-sepolia-base-1",
  isTestnet: true,
  oracleAddress: "0x1111111111111111111111111111111111111111",
  gasLimit: "300000",
};
const BASE_SEPOLIA = 10344971235874465080n;
const NOW = Date.parse("2026-10-11T16:00:00Z");
// 170 Wochen bis 2026-08-15: die letzten 4 mit je 63.000 Toten, alle anderen mit 60.000
const LAST = Date.parse("2026-08-15T00:00:00Z");
const rows = Array.from({ length: 170 }, (_, i) => ({
  week_ending_date: new Date(LAST - i * 7 * 86400000).toISOString().replace("Z", ""),
  total_deaths: String(i < 4 ? 63000 : 60000),
}));
const body = (data: unknown) => Buffer.from(JSON.stringify(data)).toString("base64");
const toHex = (b: Uint8Array) => ("0x" + Buffer.from(b).toString("hex")) as Hex;

describe("CDC-Workflow", () => {
  test("holt die Woche und schreibt den Bericht an das Oracle", () => {
    const urls: string[] = [];
    HttpActionsMock.testInstance().sendRequest = (req) => {
      urls.push(req.url);
      return { statusCode: 200, body: body(rows) };
    };
    let written: { receiver: Hex; payload: Hex; gas: bigint } | undefined;
    EvmMock.testInstance(BASE_SEPOLIA).writeReport = (req) => {
      const raw = req.report!.rawReport;
      written = { receiver: toHex(req.receiver), payload: toHex(raw.slice(raw.length - 96)), gas: req.gasConfig!.gasLimit };
      return { txStatus: "TX_STATUS_SUCCESS" };
    };

    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW }, CONFIG);
    expect(onCron(runtime)).toBe(`${LAST / 1000},252000,240000`);

    expect(decodeURIComponent(urls[0])).toContain("week_ending_date <= '2026-08-16T00:00:00.000'");
    expect(written!.receiver).toBe(CONFIG.oracleAddress as Hex);
    expect(written!.gas).toBe(300000n);
    const [week, recent, baseline] = decodeAbiParameters(
      [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }], written!.payload);
    expect([week, recent, baseline]).toEqual([BigInt(LAST / 1000), 252000n, 240000n]);
  });

  test("CDC-Fehler: kein Bericht", () => {
    HttpActionsMock.testInstance().sendRequest = () => ({ statusCode: 503, body: body("down") });
    let wrote = false;
    EvmMock.testInstance(BASE_SEPOLIA).writeReport = () => { wrote = true; return { txStatus: "TX_STATUS_SUCCESS" }; };
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW }, CONFIG);
    expect(() => onCron(runtime)).toThrow();
    expect(wrote).toBe(false);
  });

  test("abgelehnte Transaktion wird als Fehler gemeldet", () => {
    HttpActionsMock.testInstance().sendRequest = () => ({ statusCode: 200, body: body(rows) });
    EvmMock.testInstance(BASE_SEPOLIA).writeReport = () => ({ txStatus: "TX_STATUS_REVERTED", errorMessage: "OnlyForwarder" });
    const runtime = newTestRuntime<Config>(null, { timeProvider: () => NOW }, CONFIG);
    expect(() => onCron(runtime)).toThrow(/OnlyForwarder/);
  });
});
