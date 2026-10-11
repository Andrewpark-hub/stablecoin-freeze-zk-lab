// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FreezableStable} from "../00-token/FreezableStable.sol";

/// @title 01-hashed. "주소를 해시로 가리면 되지 않나" — 처음 떠올린 고친 버전
/// @notice 제안에는 keccak256(target) 만 올리고, 실행할 때 target 을 공개해 대조한다.
///         체인에는 32바이트 해시만 보이니 숨겨진 것처럼 보인다.
///
/// @dev 그런데 동결 대상은 자기 주소를 안다. keccak256(abi.encode(내 주소)) 를 한 번
///      계산해서 대기 중인 제안과 비교하면 끝이다. 후보가 "토큰 보유자 전체" 라 해도
///      수십만 번의 해시 계산은 노트북에서 1초도 안 걸린다.
///      해시는 입력이 추측 가능하면 아무것도 숨기지 못한다. 숨기려면 추측할 수 없는
///      값(salt)이 함께 들어가야 한다 → FreezeMultisigFixed.
contract FreezeMultisigHashed {
    uint256 public constant THRESHOLD = 2;

    struct Proposal {
        bytes32 commitment; // keccak256(abi.encode(target)) — salt 가 없다
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

    function propose(bytes32 commitment) external onlySigner returns (uint256 id) {
        id = proposals.length;
        proposals.push(Proposal({commitment: commitment, approvals: 0, executed: false}));
        _approve(id);
    }

    function approve(uint256 id) external onlySigner {
        _approve(id);
    }

    function execute(uint256 id, address target) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed, "EXECUTED");
        require(p.approvals >= THRESHOLD, "THRESHOLD");
        require(keccak256(abi.encode(target)) == p.commitment, "BAD_REVEAL");
        p.executed = true;
        token.freeze(target);
    }

    function _approve(uint256 id) internal {
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        proposals[id].approvals++;
    }
}
