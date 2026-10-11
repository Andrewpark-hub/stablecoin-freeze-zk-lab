// 테스트용 증명(fixture) 생성
//
// 1) 승인된 동결 사유 목록으로 깊이 4 짜리 Poseidon 머클 트리를 만든다 (= 레지스트라가 올리는 root)
// 2) 서명자 쪽 시나리오: 사유 #0 (법원 동결 명령) 으로 hacker 주소를 동결하는 증명을 만든다
// 3) 목록에 없는 사유로는 증명 자체가 만들어지지 않는 것을 확인한다
// 4) Solidity verifier 가 받는 모양으로 바꿔 test/fixtures/*.json 에 쓴다
import { buildPoseidon } from "circomlibjs";
import * as snarkjs from "snarkjs";
import jsSha3 from "js-sha3";
import { randomBytes } from "node:crypto";
import { writeFileSync, readFileSync } from "node:fs";

const DEPTH = 4;
const B = "circuits/build";
const HACKER = BigInt(process.env.HACKER);

const poseidon = await buildPoseidon();
const F = poseidon.F;
const H = (...xs) => F.toObject(poseidon(xs));

// 문서 해시를 BN254 필드 안에 들어가게 248비트로 자른다
const docHash = (s) => BigInt("0x" + jsSha3.keccak256(s)) >> 8n;

// --- 1) 승인된 사유 목록 (레지스트라가 관리) -------------------------------
// category: 1 = 법원 동결 명령, 2 = 해킹 피해 신고, 3 = 제재 대상 지정
const REASONS = [
  { category: 1n, doc: "court-order 2026-KA-0042 (phishing proceeds)" },
  { category: 2n, doc: "exchange incident report 2026-09-17" },
  { category: 3n, doc: "sanctions designation 2026-SDN-311" },
];
const leaves = Array(2 ** DEPTH).fill(0n);
REASONS.forEach((r, i) => (leaves[i] = H(r.category, docHash(r.doc))));

const levels = [leaves];
for (let d = 0; d < DEPTH; d++) {
  const prev = levels[d];
  const next = [];
  for (let i = 0; i < prev.length; i += 2) next.push(H(prev[i], prev[i + 1]));
  levels.push(next);
}
const root = levels[DEPTH][0];

function pathOf(index) {
  const pathElements = [];
  const pathIndices = [];
  for (let d = 0; d < DEPTH; d++) {
    const isRight = index % 2;
    pathElements.push(levels[d][isRight ? index - 1 : index + 1]);
    pathIndices.push(isRight);
    index = Math.floor(index / 2);
  }
  return { pathElements, pathIndices };
}

// --- 2) 동결 증명 ------------------------------------------------------------
const reason = REASONS[0];
const leaf = leaves[0];
const salt = BigInt("0x" + randomBytes(31).toString("hex")); // 서명자끼리만 공유하는 값
const { pathElements, pathIndices } = pathOf(0);

const priv = {
  category: reason.category,
  docHash: docHash(reason.doc),
  salt,
  pathElements,
  pathIndices,
};

// Solidity verifier 는 G2 점(B)의 좌표 순서가 snarkjs JSON 과 반대다
const toSol = (proof, publicSignals) => ({
  a: proof.pi_a.slice(0, 2),
  b: [
    [proof.pi_b[0][1], proof.pi_b[0][0]],
    [proof.pi_b[1][1], proof.pi_b[1][0]],
  ],
  c: proof.pi_c.slice(0, 2),
  publicSignals,
});

async function prove(circuit, input) {
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    `${B}/${circuit}_js/${circuit}.wasm`,
    `${B}/${circuit}.zkey`,
  );
  const vkey = JSON.parse(readFileSync(`circuits/${circuit}.vkey.json`, "utf8"));
  if (!(await snarkjs.groth16.verify(vkey, publicSignals, proof))) throw new Error(`${circuit}: local verify failed`);
  return toSol(proof, publicSignals);
}

// 고친 버전: commitment = Poseidon(target, leaf, salt)
const commitment = H(HACKER, leaf, salt);
const fixed = await prove("freeze_reason", { root, commitment, target: HACKER, ...priv });
// 공개 입력 순서는 회로에서 선언한 순서 (root, commitment, target) 그대로다
if (fixed.publicSignals.join() !== [root, commitment, HACKER].join()) throw new Error("public signal order");

// 순진한 버전: commitment = Poseidon(leaf, salt) — target 이 없다
const commitmentUnbound = H(leaf, salt);
const unbound = await prove("freeze_reason_unbound", { root, commitment: commitmentUnbound, ...priv });

// --- 3) 목록에 없는 사유로는 증명이 안 만들어진다 ----------------------------
let rejected = false;
try {
  await prove("freeze_reason", {
    root,
    commitment: H(HACKER, H(1n, docHash("no court order, just a request")), salt),
    target: HACKER,
    ...priv,
    docHash: docHash("no court order, just a request"),
  });
} catch (e) {
  rejected = /Assert Failed/.test(String(e));
}
if (!rejected) throw new Error("unregistered reason should not produce a proof");
console.log("  ✓ 목록에 없는 사유 → witness 생성 단계에서 Assert Failed (증명 불가)");

// --- 4) fixture 저장 (uint256 은 10진 문자열) --------------------------------
const save = (path, { publicSignals, ...rest }) =>
  writeFileSync(path, JSON.stringify(rest, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
save("test/fixtures/freeze_reason.json", { root, commitment, target: HACKER, ...fixed });
save("test/fixtures/freeze_reason_unbound.json", { root, commitment: commitmentUnbound, ...unbound });
console.log("  ✓ test/fixtures/freeze_reason.json, freeze_reason_unbound.json");
process.exit(0);
