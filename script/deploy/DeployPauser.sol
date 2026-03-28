// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Pauser } from "src/helper/Pauser.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseScript } from "../Base.s.sol";
import "@forge-std/Script.sol";
import "src/helpers/Constants.sol";

contract DeployPauser is BaseScript {

    // State variables for deployed contracts
    Pauser internal pauser;

    function run() external broadcast {
        bytes32 salt = makeSalt(broadcaster, false, ":Pauser");
        address admin = getMultisig();
        address[] memory approvedPausers = new address[](1);

        approvedPausers[0] = 0xe5CcB29Cb9C886da329098A184302E2D5Ff0cD9E;

        bytes memory creationCode = type(Pauser).creationCode;
        pauser = Pauser(CREATEX.deployCreate3(salt, abi.encodePacked(creationCode, abi.encode(admin, approvedPausers))));
        require(address(pauser) == PAUSER_EOA, "pauser salt does not resolve to expected address - check deployer");
        require(pauser.owner() == admin);
        require(pauser.isApprovedPauser(approvedPausers[0]));
        console.log("Pauser Address: ", address(pauser));
    }

}
