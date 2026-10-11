pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "lib/merkle.circom";

// 02 (고친 버전) — 동결 대상 주소를 커밋 안에 묶는다.
//
// 공개 입력: root, commitment, target
// 비공개 입력: category, docHash, salt, 머클 경로
//
// 증명하는 문장:
//   "나는 (category, docHash) 를 알고 있고, 그 사유는 root 아래의 승인 목록에 있으며,
//    서명자들이 승인한 commitment 는 바로 이 target 과 이 사유와 salt 로 만든 것이다."
//
// 체인에 공개되는 것은 target 뿐이다. 사유의 분류도, 근거 문서도 공개되지 않는다.
// target 이 커밋 해시 안에 들어 있으므로 다른 주소로 바꾸면 증명이 깨진다.
template FreezeReason(depth) {
    signal input root;
    signal input commitment;
    signal input target;

    signal input category;
    signal input docHash;
    signal input salt;
    signal input pathElements[depth];
    signal input pathIndices[depth];

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

    // 커밋 = Poseidon(target, leaf, salt)
    component commit = Poseidon(3);
    commit.inputs[0] <== target;
    commit.inputs[1] <== leafHasher.out;
    commit.inputs[2] <== salt;
    commit.out === commitment;
}

component main {public [root, commitment, target]} = FreezeReason(4);
