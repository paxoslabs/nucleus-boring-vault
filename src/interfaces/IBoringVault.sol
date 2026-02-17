// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BeforeTransferHook } from "src/interfaces/BeforeTransferHook.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface IBoringVault is IAuth {

    function manage(address target, bytes calldata data, uint256 value) external returns (bytes memory result);
    function manage(
        address[] calldata targets,
        bytes[] calldata data,
        uint256[] calldata values
    )
        external
        returns (bytes[] memory results);
    function enter(address from, ERC20 asset, uint256 assetAmount, address to, uint256 shareAmount) external;
    function exit(address to, ERC20 asset, uint256 assetAmount, address from, uint256 shareAmount) external;
    function setBeforeTransferHook(address _hook) external;
    function setNameAndSymbol(string memory _name, string memory _symbol) external;
    function hook() external view returns (BeforeTransferHook);

}
