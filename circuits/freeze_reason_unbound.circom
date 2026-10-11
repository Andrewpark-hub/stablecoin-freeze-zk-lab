pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "lib/merkle.circom";

// 02 (순진한 버전) — "승인된 사유 목록에 있는 사유로 커밋했다" 만 증명한다.
//
// 공개 입력: root, commitment
// 비공개 입력: category, docHash, salt, 머클 경로
//
// 커밋에 동결 대상 주소가 들어가 있지 않다. 그래서 이 증명은
// "누구를" 동결하는지와 무관하게 유효하다 — 증명을 본 사람은
// 대상만 바꿔서 그대로 제출할 수 있다. (test_Exploit_ProofCopiedToFreezeInnocent)
template FreezeReasonUnbound(depth) {
    signal input root;
    signal input commitment;

    signal input category;
    signal input docHash;
    signal input salt;
    signal input pathElements[depth];
    signal input pathIndices[depth];

    // 사유 leaf = Poseidon(사유 분류, 근거 문서 해시)
    component leafHasher = Poseidon(2);
    leafHasher.inputs[0] <== category;
    leafHasher.inputs[1] <== docHash;

    component tree = MerkleInclusion(depth);
    tree.leaf <== leafHasher.out;
    for (var i = 0; i < depth; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }
    tree.root === root;

    // 커밋 = Poseidon(leaf, salt) — target 이 없다
    component commit = Poseidon(2);
    commit.inputs[0] <== leafHasher.out;
    commit.inputs[1] <== salt;
    commit.out === commitment;
}

component main {public [root, commitment]} = FreezeReasonUnbound(4);
