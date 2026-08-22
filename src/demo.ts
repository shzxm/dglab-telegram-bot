import { MockDevice } from "./device.js";
import { ControlSession } from "./control.js";

const device = new MockDevice();
const collaborative = new ControlSession({
  id: "demo-collab",
  chatId: 1,
  ownerUserId: 1,
  mode: "collaboration",
  limitA: 2,
  limitB: 2,
  durationMs: 60_000,
  startedAt: 0,
  expiresAt: 0,
}, device, 200, 2, 0);
await collaborative.arm();
collaborative.addParticipant(101);
await collaborative.submit(101, { type: "strength_delta", channel: "A", delta: 1 });
await collaborative.submit(101, { type: "strength_delta", channel: "A", delta: 1 });
await collaborative.submit(101, { type: "strength_delta", channel: "A", delta: 1 });
console.log("协作模式：", collaborative.snapshot());
await collaborative.stop();

const voting = new ControlSession({
  id: "demo-voting",
  chatId: 1,
  ownerUserId: 1,
  mode: "voting",
  limitA: 10,
  limitB: 10,
  durationMs: 60_000,
  startedAt: 0,
  expiresAt: 0,
}, device, 200, 2, 0);
await voting.arm();
voting.addParticipant(201);
voting.addParticipant(202);
const action = { type: "strength_delta" as const, channel: "B" as const, delta: 1 as const };
console.log("投票第1票：", await voting.submit(201, action));
console.log("投票第2票：", await voting.submit(202, action));
console.log("投票结果：", voting.snapshot());
await voting.stop();
