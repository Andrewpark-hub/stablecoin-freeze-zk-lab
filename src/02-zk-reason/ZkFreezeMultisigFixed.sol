// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FreezableStable} from "../00-token/FreezableStable.sol";

interface IReasonVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[3] calldata pubSignals // [root, commitment, target]
    ) external view returns (bool);
}

/// @title 02-fixed. target 을 증명의 공개 입력으로 묶는다
/// @notice 회로의 커밋을 Poseidon(target, leaf, salt) 로 바꾸고, target 을 공개 입력으로
///         넣었다. 컨트랙트는 execute 로 들어온 target 을 그대로 공개 입력 자리에 넣어 검증한다.
///         다른 주소를 넣으면 공개 입력이 달라져 증명이 깨진다.
///
///         동결이 끝나면 (commitment, root) 를 대상 주소 옆에 남긴다. 체인만 보고도
///         "이 동결은 그 시점의 승인 목록에 있는 사유로 이뤄졌다" 는 것은 누구나 확인할 수 있고,
///         사유 원문은 나중에 이의제기가 들어왔을 때 서명자가 (leaf, salt) 를 열어 보이면 된다.
///         지난 글의 두 번째 질문 "동결의 이유는 체인 어디에 저장되는가" 에 대한 내 답이다.
///
/// @dev 못 고친 것 (README "그리고" 참고):
///      - 증명은 "목록에 있다" 까지만 말한다. 레지스트라가 목록에 무엇을 넣느냐는 여전히 신뢰다.
///      - 동결은 여전히 즉시 집행되고, 무고한 이용자에게 통지·이의제기 기간이 없다.
///      - 사유 하나로 몇 개의 주소든 동결할 수 있다 (nullifier 없음).
contract ZkFreezeMultisigFixed {
    uint256 public constant THRESHOLD = 2;

    struct Proposal {
        uint256 commitment; // Poseidon(target, leaf, salt)
        uint256 approvals;
        bool executed;
    }

    struct FreezeRecord {
        uint256 commitment; // 사유를 나중에 열어 보일 수 있는 봉인
        uint256 root; // 동결 시점의 승인 목록
    }

    FreezableStable public immutable token;
    IReasonVerifier public immutable verifier;
    address public immutable registrar;
    uint256 public reasonRoot;

    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public approved;
    mapping(address => FreezeRecord) public freezeRecordOf;
    Proposal[] public proposals;

    event FreezeExecuted(uint256 indexed id, address indexed target, uint256 commitment, uint256 root);

    constructor(FreezableStable _token, IReasonVerifier _verifier, address _registrar, address[3] memory signers) {
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

    function execute(uint256 id, address target, uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c)
        external
    {
        Proposal storage p = proposals[id];
        require(!p.executed, "EXECUTED");
        require(p.approvals >= THRESHOLD, "THRESHOLD");
        // target 이 공개 입력에 들어간다 — 증명은 이 주소에 대해서만 유효하다
        require(verifier.verifyProof(a, b, c, [reasonRoot, p.commitment, uint256(uint160(target))]), "BAD_PROOF");
        p.executed = true;
        freezeRecordOf[target] = FreezeRecord({commitment: p.commitment, root: reasonRoot});
        token.freeze(target);
        emit FreezeExecuted(id, target, p.commitment, reasonRoot);
    }

    function _approve(uint256 id) internal {
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        proposals[id].approvals++;
    }
}
