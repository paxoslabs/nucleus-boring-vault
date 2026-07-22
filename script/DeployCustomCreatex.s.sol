// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.23;

import { console } from "forge-std/console.sol";
import { CreateX } from "lib/createx/src/CreateX.sol";
import { Script, stdJson } from "@forge-std/Script.sol";

contract DeployCustomCreateX is Script {

    address broadcaster;
    string internal mnemonic;
    string internal constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    address immutable EXPECTED;
    bytes32 constant SALT = 0x8888888833388888888000000000000000000000000000000000000000000000;

    constructor() {
        EXPECTED = 0x1077f8ea07EA34D9F23BC39256BF234665FB391f;
        address from = vm.envOr({ name: "ETH_FROM", defaultValue: address(0) });
        if (from != address(0)) {
            broadcaster = from;
        } else {
            mnemonic = vm.envOr({ name: "MNEMONIC", defaultValue: TEST_MNEMONIC });
            (broadcaster,) = deriveRememberKey({ mnemonic: mnemonic, index: 0 });
        }
    }

    modifier broadcast() {
        vm.startBroadcast(broadcaster);
        _;
        vm.stopBroadcast();
    }

    function run() public broadcast {
        require(EXPECTED.code.length == 0, "Createx already exists on this chain");

        CreateX createx = new CreateX{ salt: SALT }();
        console.log(address(createx));
        require(address(createx) == EXPECTED, "address is not expected");
    }

}
