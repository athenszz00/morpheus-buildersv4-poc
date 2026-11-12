// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Lane 2 (Builders, Base) — Morpheus bug bounty fork PoC.
// Fork: Base block 56046051, RPC https://mainnet.base.org (DRPC 429s).
// No privileged accounts: no prank as owner/multisig/networkShareOwner.
// All MOR used is dealt to fresh unprivileged test addresses on the fork.

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transfer(address t, uint256 v) external returns (bool);
}

interface IBuilders {
    struct Subnet {
        string name;
        address admin;
        uint128 unused1;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unused2;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct Metadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function createSubnet(Subnet calldata s, Metadata calldata m) external;
    function editSubnet(bytes32 id, Subnet calldata s) external;
    function deposit(bytes32 id, uint256 amount) external;
    function withdraw(bytes32 id, uint256 amount) external;
    function claim(bytes32 id, address receiver) external;
    function getSubnetId(string memory n) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32 id) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function allSubnetsDataV4() external view returns (uint256, uint256, uint256, uint128);
    function usersData(address u, bytes32 id) external view returns (uint128, uint128, uint256, uint256);
    function subnetsData(bytes32 id) external view returns (uint128, uint256, uint256, uint256, uint256);
    function networkShare() external view returns (uint256);
    function networkShareOwner() external view returns (address);
    function setNetworkShare(uint256 v) external;
    function setNetworkShareOwner(address a) external;
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
}

interface IRewardPool {
    function getPeriodRewards(uint256 idx, uint128 from, uint128 to) external view returns (uint256);
}

interface ITreasury {
    function sendRewards(address r, uint256 a) external;
    function distributedRewards() external view returns (uint256);
}

interface IFeeConfig {
    function getFeeAndTreasuryForOperation(address s, bytes32 op) external view returns (uint256, address);
}

contract Lane2BuildersTest is Test {
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant B = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    address constant REWARD_POOL = 0xDC99a8596e395E52aba2BD08C623E1e428Dc3980;
    address constant FEE_CONFIG = 0x845FBB4B3e2207BF03087b8B94D2430AB11088eE;

    address constant ADMIN_A = address(0xA11CE);
    address constant ADMIN_B = address(0xB11CE);
    address constant STAKER_A = address(0x5A11);
    address constant STAKER_B = address(0x5B11);
    address constant VICTIM = address(0x1C71);
    address constant ATTACKER = address(0xA77AC);
    address constant RECEIVER = address(0x2EC1);

    uint256 constant BLOCK = 56046051;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", BLOCK);
        vm.deal(ADMIN_A, 10 ether);
        vm.deal(ADMIN_B, 10 ether);
        vm.deal(STAKER_A, 10 ether);
        vm.deal(STAKER_B, 10 ether);
        vm.deal(VICTIM, 10 ether);
        vm.deal(ATTACKER, 10 ether);
        vm.deal(RECEIVER, 10 ether);
        deal(MOR, STAKER_A, 100_000 ether);
        deal(MOR, STAKER_B, 100_000 ether);
        deal(MOR, VICTIM, 100_000 ether);
        deal(MOR, ATTACKER, 100_000 ether);
    }

    function _subnet(string memory name, address admin, address claimAdmin, uint256 minDep, uint128 lock)
        internal pure returns (IBuilders.Subnet memory)
    {
        return IBuilders.Subnet({
            name: name,
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: lock,
            unused2: 0,
            minimalDeposit: minDep,
            claimAdmin: claimAdmin
        });
    }

    function _meta() internal pure returns (IBuilders.Metadata memory) {
        return IBuilders.Metadata({slug: "", description: "", website: "", image: ""});
    }

    function _approve(address who, uint256 amt) internal {
        vm.prank(who);
        IERC20(MOR).approve(B, amt);
    }

    function _assertApprox(uint256 got, uint256 expected, uint256 bpsTol, string memory what) internal pure {
        require(expected > 0, "expected zero");
        uint256 diff = got > expected ? got - expected : expected - got;
        require(diff * 10_000 <= expected * bpsTol, string(abi.encodePacked(what, ": out of tolerance")));
    }

    // ---- H2: time-weighted share invariant, two equal subnets, 7 days ----
    function test_H2_timeWeightedShare() public {
        bytes32 idA = IBuilders(B).getSubnetId("lane2-alpha");
        bytes32 idB = IBuilders(B).getSubnetId("lane2-beta");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-alpha", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        vm.prank(ADMIN_B);
        IBuilders(B).createSubnet(_subnet("lane2-beta", ADMIN_B, ADMIN_B, 10 ether, 7 days), _meta());

        (,, uint256 totalBefore,) = IBuilders(B).allSubnetsData();
        uint256 t0 = block.timestamp;

        _approve(STAKER_A, 10_000 ether);
        vm.prank(STAKER_A);
        IBuilders(B).deposit(idA, 10_000 ether);
        _approve(STAKER_B, 10_000 ether);
        vm.prank(STAKER_B);
        IBuilders(B).deposit(idB, 10_000 ether);

        // deposit-then-immediately-claim must yield nothing to claim
        vm.prank(ADMIN_A);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: nothing to claim"));
        IBuilders(B).claim(idA, RECEIVER);

        vm.warp(t0 + 7 days);
        uint256 t1 = block.timestamp;
        uint256 emission = IRewardPool(REWARD_POOL).getPeriodRewards(3, uint128(t0), uint128(t1));
        uint256 emission80 = (emission * 8) / 10; // networkShare 80%
        uint256 total = totalBefore + 20_000 ether;
        uint256 expectedEach = (emission80 * 10_000 ether) / total;

        uint256 balBefore = IERC20(MOR).balanceOf(RECEIVER);
        vm.prank(ADMIN_A);
        IBuilders(B).claim(idA, RECEIVER);
        uint256 claimedA = IERC20(MOR).balanceOf(RECEIVER) - balBefore;
        vm.prank(ADMIN_B);
        IBuilders(B).claim(idB, RECEIVER);
        uint256 claimedB = IERC20(MOR).balanceOf(RECEIVER) - balBefore - claimedA;

        emit log_named_uint("emission pool3 7d (wei)", emission);
        emit log_named_uint("emission80 (wei)", emission80);
        emit log_named_uint("expectedEach (wei)", expectedEach);
        emit log_named_uint("claimedA (wei)", claimedA);
        emit log_named_uint("claimedB (wei)", claimedB);
        require(claimedA > 0 && claimedB > 0, "claims zero");
        _assertApprox(claimedA, expectedEach, 50, "claimA vs time-weighted share"); // 0.5%
        _assertApprox(claimedB, expectedEach, 50, "claimB vs time-weighted share");
        require(claimedA + claimedB <= emission80 + 1, "sum exceeds emission share");

        // claim twice in one block: second reverts
        vm.prank(ADMIN_A);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: nothing to claim"));
        IBuilders(B).claim(idA, RECEIVER);

        // usersData[address(0)] stays 0 after claims
        (,, uint256 zeroDep,) = IBuilders(B).usersData(address(0), idA);
        require(zeroDep == 0, "address(0) deposited nonzero after claim");
        (,, uint256 zeroDepB,) = IBuilders(B).usersData(address(0), idB);
        require(zeroDepB == 0, "address(0) deposited nonzero after claim B");
        // phantom subnet bytes32(0) has no deposits
        (,, uint256 phantomDep,,) = IBuilders(B).subnetsData(bytes32(0));
        require(phantomDep == 0, "phantom subnet deposited nonzero");
    }

    // ---- H8: claim -> deposit -> claim pays only new accrual; double-claim reverts ----
    function test_H8_claimDepositClaim() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-gamma");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-gamma", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        _approve(STAKER_A, 20_000 ether);
        vm.prank(STAKER_A);
        IBuilders(B).deposit(id, 10_000 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);
        uint256 t1 = block.timestamp;
        (,, uint256 totalBefore,) = IBuilders(B).allSubnetsData();
        uint256 emission1 = IRewardPool(REWARD_POOL).getPeriodRewards(3, uint128(t0), uint128(t1));
        uint256 exp1 = ((emission1 * 8) / 10 * 10_000 ether) / totalBefore;
        uint256 bal0 = IERC20(MOR).balanceOf(RECEIVER);
        vm.prank(ADMIN_A);
        IBuilders(B).claim(id, RECEIVER);
        uint256 c1 = IERC20(MOR).balanceOf(RECEIVER) - bal0;
        emit log_named_uint("H8 first claim c1 (wei)", c1);
        emit log_named_uint("H8 expected exp1 (wei)", exp1);
        _assertApprox(c1, exp1, 50, "first claim vs accrual");

        // deposit more, warp 2 more days, claim again: only second-period accrual
        vm.prank(STAKER_A);
        IBuilders(B).deposit(id, 10_000 ether);
        uint256 t2 = block.timestamp;
        vm.warp(t2 + 2 days);
        uint256 t3 = block.timestamp;
        (,, uint256 total2,) = IBuilders(B).allSubnetsData();
        uint256 emission2 = IRewardPool(REWARD_POOL).getPeriodRewards(3, uint128(t2), uint128(t3));
        uint256 exp2 = ((emission2 * 8) / 10 * 20_000 ether) / total2;
        vm.prank(ADMIN_A);
        IBuilders(B).claim(id, RECEIVER);
        uint256 c2 = IERC20(MOR).balanceOf(RECEIVER) - bal0 - c1;
        emit log_named_uint("H8 second claim c2 (wei)", c2);
        emit log_named_uint("H8 expected exp2 (wei)", exp2);
        _assertApprox(c2, exp2, 50, "second claim vs new accrual only");
        require(c2 > 0, "second claim zero");
    }

    // ---- H2/H8: withdraw caps at deposited; principal exact ----
    function test_principalWithdrawExact() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-delta");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-delta", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        _approve(VICTIM, 100 ether);
        vm.prank(VICTIM);
        IBuilders(B).deposit(id, 100 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 8 days);
        uint256 balBefore = IERC20(MOR).balanceOf(VICTIM);
        vm.prank(VICTIM);
        IBuilders(B).withdraw(id, 1000 ether); // capped at deposited
        uint256 got = IERC20(MOR).balanceOf(VICTIM) - balBefore;
        require(got == 100 ether, "withdraw did not return exactly deposited");
    }

    // ---- H5(i): victim named admin, attacker claimAdmin; victim loses nothing ----
    function test_H5_victimAdminNoLoss() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-epsilon");
        vm.prank(ATTACKER);
        IBuilders(B).createSubnet(_subnet("lane2-epsilon", VICTIM, ATTACKER, 10 ether, 7 days), _meta());
        uint256 victimBalBefore = IERC20(MOR).balanceOf(VICTIM);
        _approve(ATTACKER, 5_000 ether);
        vm.prank(ATTACKER);
        IBuilders(B).deposit(id, 5_000 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);
        uint256 recvBefore = IERC20(MOR).balanceOf(RECEIVER);
        vm.prank(ATTACKER);
        IBuilders(B).claim(id, RECEIVER);
        uint256 claimed = IERC20(MOR).balanceOf(RECEIVER) - recvBefore;
        emit log_named_uint("H5(i) attacker claimed (wei)", claimed);
        require(claimed > 0, "attacker claim zero");
        require(IERC20(MOR).balanceOf(VICTIM) == victimBalBefore, "victim lost funds");
        // victim (admin) claiming after attacker already claimed: nothing left
        vm.prank(VICTIM);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: nothing to claim"));
        IBuilders(B).claim(id, VICTIM);
    }

    // ---- H5(ii-a): raising minimalDeposit never blocks a FULL withdrawal ----
    function test_H5_minimalDepositRaiseFullWithdrawOk() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-zeta");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-zeta", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        _approve(VICTIM, 100 ether);
        vm.prank(VICTIM);
        IBuilders(B).deposit(id, 100 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 8 days);
        // admin raises minimalDeposit 10 -> 1000 MOR
        vm.prank(ADMIN_A);
        IBuilders(B).editSubnet(id, _subnet("lane2-zeta", ADMIN_A, ADMIN_A, 1000 ether, 7 days));
        // partial withdraw leaving 50 (< 1000, != 0) must revert
        vm.prank(VICTIM);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: invalid withdraw amount"));
        IBuilders(B).withdraw(id, 50 ether);
        // full withdrawal still works
        uint256 balBefore = IERC20(MOR).balanceOf(VICTIM);
        vm.prank(VICTIM);
        IBuilders(B).withdraw(id, 100 ether);
        require(IERC20(MOR).balanceOf(VICTIM) - balBefore == 100 ether, "full withdraw failed after minDeposit raise");
    }

    // ---- H5(ii-b): raising lock period freezes existing deposits (temporary, then permanent at max) ----
    function test_H5_lockRaiseFreezes() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-eta");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-eta", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        _approve(VICTIM, 100 ether);
        vm.prank(VICTIM);
        IBuilders(B).deposit(id, 100 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 8 days);
        // sanity: withdraw works before the edit
        vm.prank(VICTIM);
        IBuilders(B).withdraw(id, 1 ether);
        // re-deposit 1 ether to restore 100 (re-locks whole balance at current time)
        _approve(VICTIM, 1 ether);
        vm.prank(VICTIM);
        IBuilders(B).deposit(id, 1 ether);
        uint256 t1 = block.timestamp;
        vm.warp(t1 + 8 days);
        // admin raises lock 7d -> 365d
        vm.prank(ADMIN_A);
        IBuilders(B).editSubnet(id, _subnet("lane2-eta", ADMIN_A, ADMIN_A, 10 ether, 365 days));
        vm.prank(VICTIM);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: user withdraw is locked"));
        IBuilders(B).withdraw(id, 100 ether);
        // after 366 days the freeze lifts (temporary freeze proven)
        vm.warp(t1 + 8 days + 366 days);
        uint256 balBefore = IERC20(MOR).balanceOf(VICTIM);
        vm.prank(VICTIM);
        IBuilders(B).withdraw(id, 100 ether);
        require(IERC20(MOR).balanceOf(VICTIM) - balBefore == 100 ether, "withdraw failed after lock expiry");
    }

    function test_H5_lockRaiseToMaxPermanentFreeze() public {
        bytes32 id = IBuilders(B).getSubnetId("lane2-theta");
        vm.prank(ADMIN_A);
        IBuilders(B).createSubnet(_subnet("lane2-theta", ADMIN_A, ADMIN_A, 10 ether, 7 days), _meta());
        _approve(VICTIM, 100 ether);
        vm.prank(VICTIM);
        IBuilders(B).deposit(id, 100 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 8 days);
        // admin raises lock to type(uint128).max
        vm.prank(ADMIN_A);
        IBuilders(B).editSubnet(id, _subnet("lane2-theta", ADMIN_A, ADMIN_A, 10 ether, type(uint128).max));
        // withdraw reverts even 100 years later (uint128 overflow panic or lock revert: any revert = frozen)
        vm.warp(t0 + 8 days + 36525 days);
        vm.prank(VICTIM);
        (bool ok,) = B.call(abi.encodeWithSignature("withdraw(bytes32,uint256)", id, 100 ether));
        require(!ok, "withdraw succeeded despite max lock - freeze broken");
        // victim balance in the subnet is still 100 MOR, irretrievable
        (,, uint256 dep,) = IBuilders(B).usersData(VICTIM, id);
        require(dep == 100 ether, "victim deposit accounting changed");
    }

    // ---- networkShareOwner cannot be acquired by an unprivileged caller ----
    function test_networkShareOwnerUnacquirable() public {
        require(IBuilders(B).networkShareOwner() == address(0), "networkShareOwner not zero");
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BU: invalid caller"));
        IBuilders(B).setNetworkShare(1e25);
        vm.prank(ATTACKER);
        (bool okSso,) = B.call(abi.encodeWithSignature("setNetworkShareOwner(address)", ATTACKER));
        require(!okSso, "unprivileged setNetworkShareOwner succeeded");
        require(IBuilders(B).networkShareOwner() == address(0), "networkShareOwner changed");
        require(IBuilders(B).networkShare() == 8e24, "networkShare changed");
    }

    // ---- Treasury sendRewards is only-Builders; FeeConfig live op fees are 0 ----
    function test_treasuryOnlyBuildersAndFeesZero() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BT: the caller isn't the `BuildersV4`"));
        ITreasury(TREASURY).sendRewards(ATTACKER, 1 ether);
        (uint256 claimFee,) = IFeeConfig(FEE_CONFIG).getFeeAndTreasuryForOperation(B, bytes32("claim"));
        require(claimFee == 0, "claim fee nonzero");
        (uint256 createFee,) = IFeeConfig(FEE_CONFIG).getFeeAndTreasuryForOperation(
            B, bytes32("buildersV4.fee.subnet.create")
        );
        require(createFee == 0, "subnet-create fee nonzero");
        require(IBuilders(B).subnetCreationFeeAmount() == 0, "subnetCreationFeeAmount nonzero");
    }

    // ---- H5(iii): stale V3 slots in allSubnetsData are never read ----
    // Fork perturbation leg NOT executable in this environment: in Foundry 1.9.0
    // vm.load/vm.store do not observe forked proxy storage (proven by a probe:
    // stores to slots 2/7/101/102/106/107/115/116 left every BuildersV4 getter
    // unchanged, while the same cheatcodes work on local contracts; public Base
    // RPCs also return 0 for eth_getStorageAt on this proxy). Conclusion rests
    // on complete static proof: the only occurrences of the unused fields in
    // the 481-line BuildersV4 source are their struct declarations; no function
    // reads allSubnetsData field 0/3, SubnetData unused fields, Subnet unused
    // fields, or UserData unused fields. This test pins the live dead values
    // and proves the reward view is fully explained by live fields only.
    function test_staleSlotsDead() public {
        (uint256 f0, uint256 rate, uint256 total, uint256 f3) = IBuilders(B).allSubnetsData();
        require(f0 == 195276280000000000000000, "dead field0 value moved");
        require(f3 == 441732783519505564108328, "dead field3 value moved");
        require(rate > 0 && total == 2946066734834084407995896, "live fields moved");
        (uint256 distributed, uint256 undistributed, uint256 claimed, uint128 lastUpdate) = IBuilders(B).allSubnetsDataV4();
        require(undistributed == 0, "undistributed nonzero");
        require(lastUpdate > 0, "lastUpdate zero");
        // getCurrentSubnetsRewards() == distributed + freshEmission80 - claimed,
        // where freshEmission80 is pool-3 emission since lastUpdate x 80%: the
        // dead fields play no part -- if they entered the computation the
        // identity would fail.
        uint256 freshEmission = IRewardPool(REWARD_POOL).getPeriodRewards(3, lastUpdate, uint128(block.timestamp));
        uint256 expectedView = distributed + (freshEmission * 8) / 10 - claimed;
        uint256 viewRewards = IBuilders(B).getCurrentSubnetsRewards();
        require(viewRewards == expectedView, "reward view not explained by live fields");
        emit log_named_uint("dead field0 (wei)", f0);
        emit log_named_uint("dead field3 (wei)", f3);
        emit log_named_uint("getCurrentSubnetsRewards (wei)", viewRewards);
    }
}
