// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {FreezableStable} from "../src/00-token/FreezableStable.sol";
import {ZkFreezeMultisig, IUnboundReasonVerifier} from "../src/02-zk-reason/ZkFreezeMultisig.sol";
import {ZkFreezeMultisigFixed, IReasonVerifier} from "../src/02-zk-reason/ZkFreezeMultisigFixed.sol";
import {UnboundReasonVerifier} from "../src/02-zk-reason/verifiers/UnboundReasonVerifier.sol";
import {ReasonVerifier} from "../src/02-zk-reason/verifiers/ReasonVerifier.sol";

/// 증명은 scripts/build.sh 가 snarkjs 로 미리 만들어 test/fixtures 에 넣어 둔 것이다.
/// 시나리오: 서명자들은 "사유 #0 (법원 동결 명령)" 으로 hacker 를 동결하기로 했다.
contract ZkReasonTest is Test {
    using stdJson for string;

    struct Proof {
        uint256 root;
        uint256 commitment;
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    address s1 = makeAddr("signer1");
    address s2 = makeAddr("signer2");
    address s3 = makeAddr("signer3");
    address registrar = makeAddr("registrar");
    address hacker = makeAddr("hacker");
    address escape = makeAddr("escape");
    address innocent = makeAddr("innocent");

    uint256 constant STOLEN = 1_000_000e6;

    function _load(string memory name) internal view returns (Proof memory p) {
        string memory json = vm.readFile(string.concat("test/fixtures/", name, ".json"));
        p.root = json.readUint(".root");
        p.commitment = json.readUint(".commitment");
        uint256[] memory a = json.readUintArray(".a");
        uint256[] memory b0 = json.readUintArray(".b[0]");
        uint256[] memory b1 = json.readUintArray(".b[1]");
        uint256[] memory c = json.readUintArray(".c");
        p.a = [a[0], a[1]];
        p.b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        p.c = [c[0], c[1]];
    }

    function _signers() internal view returns (address[3] memory) {
        return [s1, s2, s3];
    }

    // ------------------------------------------------------------------
    // 02. target 이 증명에 묶여 있지 않은 버전
    // ------------------------------------------------------------------

    function _unbound() internal returns (FreezableStable token, ZkFreezeMultisig ms, Proof memory p, uint256 id) {
        p = _load("freeze_reason_unbound");
        token = new FreezableStable(hacker, STOLEN);
        ms = new ZkFreezeMultisig(token, IUnboundReasonVerifier(address(new UnboundReasonVerifier())), registrar, _signers());
        token.setFreezer(address(ms));

        vm.prank(registrar);
        ms.setReasonRoot(p.root);

        vm.prank(s1);
        id = ms.propose(p.commitment);
        vm.prank(s2);
        ms.approve(id);
    }

    /// 기준선: 서명자가 직접 제출하면 정확히 hacker 가 동결된다.
    function test_Zk_ValidProofFreezesTarget() public {
        (FreezableStable token, ZkFreezeMultisig ms, Proof memory p, uint256 id) = _unbound();

        vm.prank(s1);
        ms.execute(id, hacker, p.a, p.b, p.c);

        assertTrue(token.frozen(hacker), "target frozen with a verified reason");
    }

    /// 서명자의 execute 가 멤풀에 올라온 순간, hacker 가 같은 증명을 복사해
    /// 대상만 innocent 로 바꿔 먼저 제출한다. 증명은 그대로 통과한다.
    function test_Exploit_ProofCopiedToFreezeInnocent() public {
        (FreezableStable token, ZkFreezeMultisig ms, Proof memory p, uint256 id) = _unbound();

        // --- hacker 의 선행 트랜잭션 (가스를 더 내고 앞에 끼어든다) ---
        vm.prank(hacker);
        ms.execute(id, innocent, p.a, p.b, p.c);
        vm.prank(hacker);
        token.transfer(escape, STOLEN);

        // --- 원래 서명자의 트랜잭션은 이미 소모된 제안이라 실패한다 ---
        vm.prank(s1);
        vm.expectRevert("EXECUTED");
        ms.execute(id, hacker, p.a, p.b, p.c);

        assertTrue(token.frozen(innocent), "an uninvolved address got frozen");
        assertFalse(token.frozen(hacker), "the real target is untouched");
        assertEq(token.balanceOf(escape), STOLEN, "and the funds are gone");
    }

    // ------------------------------------------------------------------
    // 02-fixed. target 을 공개 입력으로 묶은 버전
    // ------------------------------------------------------------------

    function _fixed() internal returns (FreezableStable token, ZkFreezeMultisigFixed ms, Proof memory p, uint256 id) {
        p = _load("freeze_reason");
        // fixture 의 target 이 이 테스트의 hacker 와 같은 주소인지부터 확인
        assertEq(vm.readFile("test/fixtures/freeze_reason.json").readUint(".target"), uint256(uint160(hacker)));

        token = new FreezableStable(hacker, STOLEN);
        ms = new ZkFreezeMultisigFixed(token, IReasonVerifier(address(new ReasonVerifier())), registrar, _signers());
        token.setFreezer(address(ms));

        vm.prank(registrar);
        ms.setReasonRoot(p.root);

        vm.prank(s1);
        id = ms.propose(p.commitment);
        vm.prank(s2);
        ms.approve(id);
    }

    /// 같은 선행 공격. 이번엔 target 을 바꾸면 공개 입력이 달라져 증명이 깨진다.
    /// 원래 트랜잭션은 그대로 성공하고, 동결 기록에는 사유 원문 없이 봉인만 남는다.
    function test_Fix_ProofIsBoundToTarget() public {
        (FreezableStable token, ZkFreezeMultisigFixed ms, Proof memory p, uint256 id) = _fixed();

        vm.prank(hacker);
        vm.expectRevert("BAD_PROOF");
        ms.execute(id, innocent, p.a, p.b, p.c);

        vm.prank(s1);
        ms.execute(id, hacker, p.a, p.b, p.c);

        assertTrue(token.frozen(hacker), "the approved target is frozen");
        assertFalse(token.frozen(innocent), "nobody else is");
        assertEq(token.balanceOf(hacker), STOLEN, "funds caught in place");

        (uint256 commitment, uint256 root) = ms.freezeRecordOf(hacker);
        assertEq(commitment, p.commitment, "sealed reason stored next to the target");
        assertEq(root, p.root, "with the reason list it was checked against");
    }

    /// 01-fixed 에서는 "사유 없음" 으로도 동결됐다(test_Limit_RevealedReasonIsUncheckable).
    /// 여기서는 승인 목록에 없는 사유로 만든 커밋이면 서명자 둘이 합의해도 동결할 수 없다.
    /// (목록에 없는 사유로는 증명 자체가 안 만들어지는 것은 scripts/make-fixtures.mjs 에서 확인)
    function test_Fix_NoRegisteredReasonNoFreeze() public {
        (FreezableStable token, ZkFreezeMultisigFixed ms, Proof memory p,) = _fixed();

        uint256 noReasonCommitment = uint256(keccak256("signers agreed, but no registered reason")) >> 8;
        vm.prank(s1);
        uint256 id2 = ms.propose(noReasonCommitment);
        vm.prank(s2);
        ms.approve(id2);

        vm.prank(s1);
        vm.expectRevert("BAD_PROOF");
        ms.execute(id2, hacker, p.a, p.b, p.c);

        assertFalse(token.frozen(hacker), "approvals alone are not enough");
    }

    /// 한계: 레지스트라가 목록을 갱신(root 변경)하면, 이미 만들어 둔 증명이 전부 무효가 된다.
    /// 새 사유를 하나 추가했을 뿐인데 진행 중이던 동결이 멈춘다. 해커 입장에선 시간을 번다.
    /// Tornado Cash 처럼 최근 root 여러 개를 기억하는 방식이 필요해 보인다.
    function test_Limit_RootUpdateInvalidatesPendingProof() public {
        (FreezableStable token, ZkFreezeMultisigFixed ms, Proof memory p, uint256 id) = _fixed();

        vm.prank(registrar);
        ms.setReasonRoot(p.root + 1); // 사유 하나가 추가됐다고 가정

        vm.prank(s1);
        vm.expectRevert("BAD_PROOF");
        ms.execute(id, hacker, p.a, p.b, p.c);

        assertFalse(token.frozen(hacker), "a legitimate, approved freeze is now stuck");
    }
}
