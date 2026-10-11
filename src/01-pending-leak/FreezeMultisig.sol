// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FreezableStable} from "../00-token/FreezableStable.sol";

/// @title 01. 동결 멀티시그 — 대기 중인 제안이 그대로 공개된다
/// @notice USDT 의 owner 는 단일 키가 아니라 멀티시그였고, 동결은 서명이 다 모일 때까지
///         기다린다. 이 버전은 그 구조를 그대로 옮겼다: propose(target) → approve → execute.
///
/// @dev 문제는 서명을 기다리는 동안 proposals[id].target 이 누구에게나 보인다는 점이다.
///      BitOK 분석에서 본 "동결 예정 지갑에서 자금이 먼저 빠져나간" 경우가 이 모양이다.
///      동결 대상은 체인을 지켜보다가 자기 주소가 올라오면, 마지막 서명 전에 옮기면 된다.
///      코드는 설계대로 정확히 작동한다. 버그가 아니라 "대기 시간이 공개 신호가 되는" 구조다.
contract FreezeMultisig {
    uint256 public constant THRESHOLD = 2;

    struct Proposal {
        address target; // 평문으로 저장된다 — 여기서 샌다
        uint256 approvals;
        bool executed;
    }

    FreezableStable public immutable token;
    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public approved;
    Proposal[] public proposals;

    constructor(FreezableStable _token, address[3] memory signers) {
        token = _token;
        for (uint256 i = 0; i < 3; i++) isSigner[signers[i]] = true;
    }

    modifier onlySigner() {
        require(isSigner[msg.sender], "NOT_SIGNER");
        _;
    }

    function propose(address target) external onlySigner returns (uint256 id) {
        id = proposals.length;
        proposals.push(Proposal({target: target, approvals: 0, executed: false}));
        _approve(id);
    }

    function approve(uint256 id) external onlySigner {
        _approve(id);
    }

    function execute(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed, "EXECUTED");
        require(p.approvals >= THRESHOLD, "THRESHOLD");
        p.executed = true;
        token.freeze(p.target);
    }

    function _approve(uint256 id) internal {
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        proposals[id].approvals++;
    }
}
