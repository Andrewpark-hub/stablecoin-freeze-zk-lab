// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title 00. 동결 가능한 스테이블코인 (USDC blacklist 의 최소 모형)
/// @notice USDC 의 blacklist 처럼, 동결된 주소는 보내지도 받지도 못한다.
///         지난 글에서 읽은 대로 이 토큰 자체는 "누가 동결하는가" 만 확인한다.
///         어떤 절차로 동결하는지는 전부 freezer 쪽(01, 02 의 멀티시그)에 있다.
///
/// @dev 실험에 필요한 transfer 만 있는 최소 예제다. ERC-20 전체가 아니다.
///      freezer 는 배포 직후 한 번만 정할 수 있다(멀티시그가 토큰 주소를 알아야
///      하므로 생성자에서 바로 넣을 수 없다).
contract FreezableStable {
    address public immutable admin;
    address public freezer;

    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public frozen;

    event Frozen(address indexed account);

    constructor(address holder, uint256 supply) {
        admin = msg.sender;
        balanceOf[holder] = supply;
    }

    function setFreezer(address _freezer) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(freezer == address(0), "FREEZER_SET");
        freezer = _freezer;
    }

    function freeze(address account) external {
        require(msg.sender == freezer, "NOT_FREEZER");
        frozen[account] = true;
        emit Frozen(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "FROZEN");
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
