#!/usr/bin/env bash
# 회로 컴파일 → trusted setup → Solidity verifier 생성 → 테스트용 증명(fixture) 생성
#
# ⚠️ trusted setup 은 학습용으로 로컬에서 "혼자" 기여한 것이다. 기여자가 한 명이면 그 사람이
#    toxic waste 를 알 수 있으므로 실제 서비스라면 다자간 세리머니가 필요하다.
set -euo pipefail
cd "$(dirname "$0")/.."

B=circuits/build
mkdir -p "$B" src/02-zk-reason/verifiers test/fixtures

echo "[1/4] circom 컴파일"
for c in freeze_reason freeze_reason_unbound; do
  npx circom2 "circuits/$c.circom" --r1cs --wasm -l node_modules -o "$B" > /dev/null
done

echo "[2/4] Powers of Tau (phase 1, 2^12 — 제약 ~3,200 개)"
if [ ! -f "$B/pot12_final.ptau" ]; then
  npx snarkjs powersoftau new bn128 12 "$B/pot12_0000.ptau" > /dev/null
  npx snarkjs powersoftau contribute "$B/pot12_0000.ptau" "$B/pot12_0001.ptau" \
    --name="local learning contribution" -e="$(head -c 32 /dev/urandom | xxd -p)" > /dev/null
  npx snarkjs powersoftau prepare phase2 "$B/pot12_0001.ptau" "$B/pot12_final.ptau" > /dev/null
fi

echo "[3/4] Groth16 setup (phase 2) + verifier 생성"
gen_verifier () {  # $1 = 회로 이름, $2 = Solidity 컨트랙트 이름
  npx snarkjs groth16 setup "$B/$1.r1cs" "$B/pot12_final.ptau" "$B/$1_0000.zkey" > /dev/null
  npx snarkjs zkey contribute "$B/$1_0000.zkey" "$B/$1.zkey" \
    --name="local learning contribution" -e="$(head -c 32 /dev/urandom | xxd -p)" > /dev/null
  npx snarkjs zkey export verificationkey "$B/$1.zkey" "circuits/$1.vkey.json" > /dev/null
  npx snarkjs zkey export solidityverifier "$B/$1.zkey" "src/02-zk-reason/verifiers/$2.sol" > /dev/null
  # snarkjs 는 항상 Groth16Verifier 라는 이름으로 뽑는다 — 두 개를 같이 쓰려고 이름만 바꾼다
  sed -i '' "s/contract Groth16Verifier/contract $2/" "src/02-zk-reason/verifiers/$2.sol"
}
gen_verifier freeze_reason ReasonVerifier
gen_verifier freeze_reason_unbound UnboundReasonVerifier

echo "[4/4] 테스트용 증명 생성"
# Foundry 의 makeAddr("hacker") = keccak256("hacker") 를 "개인키" 로 쓴 주소 (해시의 뒷 20바이트가 아니다)
export HACKER="$(cast wallet address --private-key "$(cast keccak hacker)")"
node scripts/make-fixtures.mjs
echo "done"
