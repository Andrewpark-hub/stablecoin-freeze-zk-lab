// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {FreezableStable} from "../src/00-token/FreezableStable.sol";
import {FreezeMultisig} from "../src/01-pending-leak/FreezeMultisig.sol";
import {FreezeMultisigHashed} from "../src/01-pending-leak/FreezeMultisigHashed.sol";
import {FreezeMultisigFixed} from "../src/01-pending-leak/FreezeMultisigFixed.sol";

contract PendingLeakTest is Test {
    address s1 = makeAddr("signer1");
    address s2 = makeAddr("signer2");
    address s3 = makeAddr("signer3");
    address hacker = makeAddr("hacker"); // 해킹 자금을 들고 있는 주소 (동결 대상)
    address escape = makeAddr("escape"); // 해커가 미리 만들어 둔 새 주소

    uint256 constant STOLEN = 1_000_000e6; // 100만 USDC 상당

    bytes32 constant REASON = keccak256("case-2026-0042: phishing proceeds");
    bytes32 constant SALT = keccak256("random 32 bytes shared off-chain by signers");

    function _token() internal returns (FreezableStable token) {
        token = new FreezableStable(hacker, STOLEN);
    }

    function _signers() internal view returns (address[3] memory) {
        return [s1, s2, s3];
    }

    /// 기준선: 대상이 아무것도 안 하면 취약 버전도 정확히 동결한다.
    /// 그래서 "동결이 되느냐" 만 보는 테스트로는 문제가 드러나지 않는다.
    function test_Freeze_WorksWhenTargetIsAsleep() public {
        FreezableStable token = _token();
        FreezeMultisig ms = new FreezeMultisig(token, _signers());
        token.setFreezer(address(ms));

        vm.prank(s1);
        uint256 id = ms.propose(hacker);
        vm.prank(s2);
        ms.approve(id);
        vm.prank(s1);
        ms.execute(id);

        assertTrue(token.frozen(hacker), "target frozen");
        assertEq(token.balanceOf(hacker), STOLEN, "funds caught");
    }

    /// 첫 서명과 두 번째 서명 사이, 제안은 체인에 평문으로 떠 있다.
    /// 해커는 proposals(id) 를 읽고 자기 주소를 발견한 뒤 자금을 옮긴다.
    function test_Exploit_TargetReadsPendingProposalAndEscapes() public {
        FreezableStable token = _token();
        FreezeMultisig ms = new FreezeMultisig(token, _signers());
        token.setFreezer(address(ms));

        vm.prank(s1);
        uint256 id = ms.propose(hacker);

        // --- 대기 구간: s2 의 서명을 기다리는 동안 ---
        (address pendingTarget,,) = ms.proposals(id);
        if (pendingTarget == hacker) {
            vm.prank(hacker);
            token.transfer(escape, STOLEN);
        }

        vm.prank(s2);
        ms.approve(id);
        vm.prank(s1);
        ms.execute(id);

        assertTrue(token.frozen(hacker), "freeze executed as designed");
        assertEq(token.balanceOf(hacker), 0, "but the frozen address is empty");
        assertEq(token.balanceOf(escape), STOLEN, "funds left before the last signature");
    }

    /// "해시로 가리면 되겠지" 버전. 해커는 자기 주소의 해시를 한 번 계산하면 된다.
    function test_Exploit_UnsaltedHashIsGuessable() public {
        FreezableStable token = _token();
        FreezeMultisigHashed ms = new FreezeMultisigHashed(token, _signers());
        token.setFreezer(address(ms));

        vm.prank(s1);
        uint256 id = ms.propose(keccak256(abi.encode(hacker)));

        // --- 대기 구간 ---
        (bytes32 pending,,) = ms.proposals(id);
        if (pending == keccak256(abi.encode(hacker))) {
            vm.prank(hacker);
            token.transfer(escape, STOLEN);
        }

        vm.prank(s2);
        ms.approve(id);
        vm.prank(s1);
        ms.execute(id, hacker);

        assertEq(token.balanceOf(hacker), 0, "hash without salt hid nothing");
        assertEq(token.balanceOf(escape), STOLEN, "funds escaped anyway");
    }

    /// 수정본: salt 가 들어간 커밋은 해커가 같은 방법으로 맞춰볼 수 없다.
    /// 해커는 자기가 대상인지 모른 채로 기다리고, 공개와 동결이 한 트랜잭션에서 일어난다.
    function test_Fix_SaltedCommitHidesTargetUntilExecution() public {
        FreezableStable token = _token();
        FreezeMultisigFixed ms = new FreezeMultisigFixed(token, _signers());
        token.setFreezer(address(ms));

        vm.prank(s1);
        uint256 id = ms.propose(keccak256(abi.encode(hacker, REASON, SALT)));

        // --- 대기 구간: 해커가 시도할 수 있는 것은 salt 없는 추측뿐이다 ---
        (bytes32 pending,,) = ms.proposals(id);
        assertTrue(pending != keccak256(abi.encode(hacker)), "unsalted guess does not match");
        assertTrue(pending != keccak256(abi.encode(hacker, REASON, bytes32(0))), "guess without salt does not match");

        vm.prank(s2);
        ms.approve(id);
        vm.prank(s1);
        ms.execute(id, hacker, REASON, SALT);

        assertTrue(token.frozen(hacker), "target frozen");
        assertEq(token.balanceOf(hacker), STOLEN, "funds caught in place");

        // 동결 이후에는 옮길 수 없다
        vm.prank(hacker);
        vm.expectRevert("FROZEN");
        token.transfer(escape, 1);
    }

    /// 수정본은 커밋과 다른 대상을 공개하면 거부한다. (승인받은 것과 다른 주소를 동결할 수 없다)
    function test_Fix_RevealMustMatchCommitment() public {
        FreezableStable token = _token();
        FreezeMultisigFixed ms = new FreezeMultisigFixed(token, _signers());
        token.setFreezer(address(ms));

        vm.prank(s1);
        uint256 id = ms.propose(keccak256(abi.encode(hacker, REASON, SALT)));
        vm.prank(s2);
        ms.approve(id);

        vm.prank(s1);
        vm.expectRevert("BAD_REVEAL");
        ms.execute(id, escape, REASON, SALT);
    }

    /// 한계: 공개되는 reasonHash 는 아무 32바이트여도 된다.
    /// 서명자 둘이 합의하면 "사유 없음" 으로도 동결된다. 체인은 사유의 정당성을 모른다.
    function test_Limit_RevealedReasonIsUncheckable() public {
        FreezableStable token = _token();
        FreezeMultisigFixed ms = new FreezeMultisigFixed(token, _signers());
        token.setFreezer(address(ms));

        address innocent = makeAddr("innocent");
        bytes32 noReason = keccak256("no reason at all");

        vm.prank(s1);
        uint256 id = ms.propose(keccak256(abi.encode(innocent, noReason, SALT)));
        vm.prank(s2);
        ms.approve(id);
        vm.prank(s1);
        ms.execute(id, innocent, noReason, SALT);

        assertTrue(token.frozen(innocent), "frozen with a meaningless reason");
    }
}
