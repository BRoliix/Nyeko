import { describe, expect, it } from "vitest";
import { accessFromProtocols, accessKeyOk, parseJoinProof } from "../src/protocol";

// Nyeko's phone web app: a browser cannot set Authorization on a WebSocket, so it offers the access key as a sub-protocol.
describe("access key as a sub-protocol (browsers)", () => {
  const key = "A".repeat(43);
  const join = "B".repeat(43);
  const offered = `coucou.v1, coucou.join.${join}, coucou.access.${key}`;

  it("reads it from the offered sub-protocols", () => {
    expect(accessFromProtocols(offered)).toBe(key);
    expect(accessFromProtocols("coucou.v1")).toBeNull();
    expect(accessFromProtocols(null)).toBeNull();
    expect(accessFromProtocols(`coucou.access.${key}, coucou.access.${key}`)).toBeNull(); // only one
    expect(accessFromProtocols("coucou.access.no spaces")).toBeNull();
  });

  it("is accepted like the header, and still fails closed", async () => {
    expect(await accessKeyOk(key, null, offered)).toBe(true);
    expect(await accessKeyOk(key, `Bearer ${key}`)).toBe(true);
    expect(await accessKeyOk("C".repeat(43), null, offered)).toBe(false);
    expect(await accessKeyOk(undefined, null, offered)).toBe(false);
    expect(await accessKeyOk(key, null, null)).toBe(false);
  });

  it("does not disturb the join proof", () => {
    expect(parseJoinProof(offered)).toBe(join);
  });
});
