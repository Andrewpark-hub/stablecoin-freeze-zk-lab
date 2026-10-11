// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FreezableStable} from "../00-token/FreezableStable.sol";

/// @title 01-fixed. 커밋-리빌 — 대상·사유·salt 를 함께 묶어서 가린다
/// @notice 제안에는 keccak256(target, reasonHash, salt) 만 올린다. salt 는 서명자들만
///         오프체인으로 공유하는 무작위 32바이트라, 동결 대상이 자기 주소를 넣어 봐도
///         대기 중인 제안과 맞춰볼 방법이 없다. 대상은 execute 트랜잭션 안에서 처음
///         공개되고, 같은 트랜잭션에서 바로 동결된다 — 공개와 집행 사이에 틈이 없다.
///
/// @dev 고친 것: 대기 시간이 더 이상 공개 신호가 아니다.
///      못 고친 것: execute 에서 공개되는 reasonHash 는 그냥 32바이트다. 그게 법원 명령인지,
///      해킹 신고인지, 아무 문자열인지 체인은 확인할 수 없다(test_Limit_RevealedReasonIsUncheckable).
///      지난 글의 두 번째 질문 "동결 사유는 어디에 저장되는가" 는 여전히 비어 있다.
///      사유를 공개하지 않으면서 그 사유가 승인된 것임을 보이려면 ZK 가 필요하다 → 02.
contract FreezeMultisigFixed {
    uint256 public constant THRESHOLD = 2;

    struct Proposal {
        bytes32 commitment; // keccak256(abi.encode(target, reasonHash, salt))
        uint256 approvals;
        bool executed;
    }

    FreezableStable public immutable token;
    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public approved;
    Proposal[] public proposals;

    event FreezeExecuted(uint256 indexed id, address indexed target, bytes32 reasonHash);

    constructor(FreezableStable _token, address[3] memory signers) {
        token = _token;
        for (uint256 i = 0; i < 3; i++) isSigner[signers[i]] = true;
    }

    modifier onlySigner() {
        require(isSigner[msg.sender], "NOT_SIGNER");
        _;
    }

    function propose(bytes32 commitment) external onlySigner returns (uint256 id) {
        id = proposals.length;
        proposals.push(Proposal({commitment: commitment, approvals: 0, executed: false}));
        _approve(id);
    }

    function approve(uint256 id) external onlySigner {
        _approve(id);
    }

    function execute(uint256 id, address target, bytes32 reasonHash, bytes32 salt) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed, "EXECUTED");
        require(p.approvals >= THRESHOLD, "THRESHOLD");
        require(keccak256(abi.encode(target, reasonHash, salt)) == p.commitment, "BAD_REVEAL");
        p.executed = true;
        token.freeze(target);
        // 사유는 해시로 남긴다. 다만 이 해시가 "정당한 사유" 인지는 아무도 확인하지 않았다.
        emit FreezeExecuted(id, target, reasonHash);
    }

    function _approve(uint256 id) internal {
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        proposals[id].approvals++;
    }
}
