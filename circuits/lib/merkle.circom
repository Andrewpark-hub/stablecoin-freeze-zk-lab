pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";

// 머클 포함 증명: leaf 가 root 아래에 있다는 것을, 형제 노드(pathElements)와
// 좌우 방향(pathIndices)으로 루트까지 다시 계산해서 보인다.
template MerkleInclusion(depth) {
    signal input leaf;
    signal input pathElements[depth];
    signal input pathIndices[depth]; // 0 = 내가 왼쪽, 1 = 내가 오른쪽
    signal output root;

    component hashers[depth];
    signal cur[depth + 1];
    signal left[depth];
    signal right[depth];

    cur[0] <== leaf;

    for (var i = 0; i < depth; i++) {
        // pathIndices 가 0 또는 1 이라는 제약. 이게 없으면 0.5 같은 값으로
        // 좌우를 "섞은" 가짜 경로를 만들 수 있다.
        pathIndices[i] * (1 - pathIndices[i]) === 0;

        // s=0 이면 (cur, sibling), s=1 이면 (sibling, cur)
        left[i] <== cur[i] + pathIndices[i] * (pathElements[i] - cur[i]);
        right[i] <== pathElements[i] + pathIndices[i] * (cur[i] - pathElements[i]);

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== left[i];
        hashers[i].inputs[1] <== right[i];
        cur[i + 1] <== hashers[i].out;
    }

    root <== cur[depth];
}
