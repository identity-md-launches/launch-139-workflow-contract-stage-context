// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PVP} from "../src/PVP.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Opcodes} from "./utils/Opcodes.sol";

/// @dev The exact artifacts the manifest attests, deployed the way the services will: the token's
/// bare creation code from the factory, and the hook's creation code with the single Sepolia
/// PoolManager word appended, at a CREATE2 address carrying flags 200.
contract DeploymentTest is Test {
    /// @dev The Sepolia PoolManager named by the approved workflow; the only constructor argument.
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant UPDATER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;

    address factory = makeAddr("factory");

    function setUp() public {
        // Put real PoolManager code where the constructor argument points, so this is the closest an
        // offline test can get to Sepolia. Only the constructor is exercised at this address.
        PoolManager local = new PoolManager(address(this));
        vm.etch(SEPOLIA_POOL_MANAGER, address(local).code);
    }

    function manifestCreationCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(PvPadHook).creationCode, abi.encode(SEPOLIA_POOL_MANAGER));
    }

    function test_tokenFromTheFactory() public {
        vm.prank(factory);
        PVP pvp = new PVP();
        assertEq(pvp.totalSupply(), 1e27);
        assertEq(pvp.balanceOf(factory), 1e27);
        assertEq(pvp.decimals(), 18);
        assertEq(pvp.name(), "Pepe Values Pepe");
        assertEq(pvp.symbol(), "PVP");
        assertFalse(Opcodes.hasEscapeHatch(address(pvp).code));
    }

    function test_hookAtAMinedAddressWithTheSepoliaManager() public {
        bytes memory creationCode = manifestCreationCode();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.PVPAD_HOOK, creationCode, 0);

        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        assertEq(deployed, predicted);
        PvPadHook hook = PvPadHook(payable(deployed));

        assertEq(HookFlags.flagsOf(deployed), 200);
        assertEq(uint160(deployed) & HookFlags.BEFORE_INITIALIZE, 0);
        assertEq(address(hook.poolManager()), SEPOLIA_POOL_MANAGER);
        assertEq(hook.updater(), UPDATER);
        assertEq(hook.INITIAL_UPDATER(), UPDATER);
        assertEq(hook.claimPrice(), 0.01 ether);
        assertEq(hook.FEE_BPS(), 100);
        assertEq(hook.BUMP_BPS(), 1000);
        assertEq(hook.king(), address(0));
        assertEq(hook.beneficiary(), address(0));

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta);
        assertFalse(p.beforeInitialize);

        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        assertFalse(Opcodes.hasEscapeHatch(runtime));
    }

    function test_hookRefusesAnyOtherAddress() public {
        bytes memory creationCode = manifestCreationCode();
        // Find a salt whose address carries beforeInitialize on top: the constructor must refuse it.
        (address wrong, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.PVPAD_HOOK | HookFlags.BEFORE_INITIALIZE, creationCode, 0);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        new PvPadHook{salt: salt}(IPoolManager(SEPOLIA_POOL_MANAGER));
    }

    function test_creationCodeCarriesOnlyThePoolManagerWord() public pure {
        bytes memory creationCode = manifestCreationCode();
        bytes memory bare = type(PvPadHook).creationCode;
        assertEq(creationCode.length, bare.length + 32);
        bytes32 last;
        assembly ("memory-safe") {
            last := mload(add(add(creationCode, 0x20), sub(mload(creationCode), 0x20)))
        }
        assertEq(address(uint160(uint256(last))), SEPOLIA_POOL_MANAGER);
    }
}
