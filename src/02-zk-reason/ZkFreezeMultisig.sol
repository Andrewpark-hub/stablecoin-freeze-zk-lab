// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FreezableStable} from "../00-token/FreezableStable.sol";

interface IUnboundReasonVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[2] calldata pubSignals // [root, commitment]
    ) external view returns (bool);
}

/// @title 02. ZK 로 동결 사유를 증명한다 — 그런데 증명이 "누구를" 에 묶여 있지 않다
/// @notice 01-fixed 의 남은 문제(공개된 reasonHash 를 아무도 확인 못 함)를 ZK 로 푼다.
///         레지스트라(예: 법원·감독기관 역할)가 승인된 동결 사유 목록의 머클 루트만 올리고,
///         동결할 때는 "이 커밋은 그 목록에 있는 사유로 만들었다" 는 Groth16 증명을 낸다.
///         사유의 분류도, 근거 문서도 체인에 공개되지 않는다.
///
///         증명 자체가 권한이므로 execute 는 누구나 호출할 수 있게 했다(릴레이어가 대신
///         제출해도 되도록). 서명자 승인 + 유효한 증명이 있으면 동결된다.
///
/// @dev 문제: 회로의 커밋이 Poseidon(leaf, salt) 라서 target 이 증명 안에 없다.
///      서명자가 execute(id, hacker, proof) 를 멤풀에 올리면, 그걸 본 누구든 같은 proof 로
///      execute(id, 아무주소, proof) 를 먼저 넣을 수 있다. 증명은 여전히 유효하다 —
///      증명이 말하는 문장에 "누구를" 이 없기 때문이다.
///      결과: 엉뚱한 주소가 동결되고, 제안은 소모되고, 진짜 대상은 경고까지 받는다.
contract ZkFreezeMultisig {
    uint256 public constant THRESHOLD = 2;

    struct Proposal {
        uint256 commitment; // Poseidon(leaf, salt) — 회로가 계산하는 값과 같아야 한다
        uint256 approvals;
        bool executed;
    }

    FreezableStable public immutable token;
    IUnboundReasonVerifier public immutable verifier;
    address public immutable registrar;
    uint256 public reasonRoot; // 승인된 동결 사유 목록의 머클 루트

    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public approved;
    Proposal[] public proposals;

    constructor(FreezableStable _token, IUnboundReasonVerifier _verifier, address _registrar, address[3] memory signers) {
        token = _token;
        verifier = _verifier;
        registrar = _registrar;
        for (uint256 i = 0; i < 3; i++) isSigner[signers[i]] = true;
    }

    modifier onlySigner() {
        require(isSigner[msg.sender], "NOT_SIGNER");
        _;
    }

    function setReasonRoot(uint256 root) external {
        require(msg.sender == registrar, "NOT_REGISTRAR");
        reasonRoot = root;
    }

    function propose(uint256 commitment) external onlySigner returns (uint256 id) {
        id = proposals.length;
        proposals.push(Proposal({commitment: commitment, approvals: 0, executed: false}));
        _approve(id);
    }

    function approve(uint256 id) external onlySigner {
        _approve(id);
    }

    /// 누구나 호출 가능 — 권한은 서명자 승인과 증명에서 온다
    function execute(uint256 id, address target, uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c)
        external
    {
        Proposal storage p = proposals[id];
        require(!p.executed, "EXECUTED");
        require(p.approvals >= THRESHOLD, "THRESHOLD");
        // target 은 증명 검증에 들어가지 않는다 — 여기가 구멍이다
        require(verifier.verifyProof(a, b, c, [reasonRoot, p.commitment]), "BAD_PROOF");
        p.executed = true;
        token.freeze(target);
    }

    function _approve(uint256 id) internal {
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        proposals[id].approvals++;
    }
}
