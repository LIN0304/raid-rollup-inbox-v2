// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IBeaconRoots } from "../interfaces/IBeaconRoots.sol";

/// @notice Minimal wrapper to future‑proof the address change of the beacon‑root contract
///         without redeploying the entire Raid stack.
contract BeaconOracle {
    /*//////////////////////////////////////////////////////////////
                               CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroAddress();
    error NotAdmin(address sender);
    
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    address public beaconRoots; // EIP-4788 address
    address public admin;      // Admin for potential updates
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event BeaconRootsUpdated(address oldAddress, address newAddress);
    event AdminChanged(address oldAdmin, address newAdmin);
    
    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _beaconRoots) {
        if (_beaconRoots == address(0)) revert ZeroAddress();
        beaconRoots = _beaconRoots;
        admin = msg.sender;
    }
    
    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Updates the beacon roots contract address
    /// @param newBeaconRoots The new beacon roots contract address
    function updateBeaconRoots(address newBeaconRoots) external onlyAdmin {
        if (newBeaconRoots == address(0)) revert ZeroAddress();
        address oldBeaconRoots = beaconRoots;
        beaconRoots = newBeaconRoots;
        emit BeaconRootsUpdated(oldBeaconRoots, newBeaconRoots);
    }
    
    /// @notice Transfers admin role to a new address
    /// @param newAdmin The new admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/
    /// @notice Gets the beacon root at a specific slot
    /// @param slot The beacon chain slot
    /// @return root The beacon root at the slot
    function rootAt(uint64 slot) external view returns (bytes32 root) {
        return IBeaconRoots(beaconRoots).getBeaconRoot(slot);
    }
}