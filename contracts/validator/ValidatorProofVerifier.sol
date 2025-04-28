// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IBeaconRoots } from "../interfaces/IBeaconRoots.sol";
import { MerkleProofLib } from "../utils/MerkleProofLib.sol";

/// @title ValidatorProofVerifier
/// @notice Verifies the validity of a validator proof against the beacon chain
library ValidatorProofVerifier {
    /*//////////////////////////////////////////////////////////////
                               CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidBeaconRoot(uint64 slot);
    error InvalidMerkleProof();
    error InvalidProposerIndex(uint64 index, uint64 maxValidators);

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/
    struct Proof {
        uint64  slot;          // Beacon‑chain slot for `unsafeHead`
        uint64  proposerIndex; // Validator index of the slot‑leader
        address proposerAddr;  // Execution‑layer address claimed to have the slot
        bytes32[] branch;      // SSZ / Merkle multi‑proof
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    // Max validator index in the beacon chain (for sanity checking)
    uint64 private constant MAX_VALIDATOR_INDEX = 1_000_000;

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VERIFICATION
    //////////////////////////////////////////////////////////////*/
    /// @notice Verifies a validator proof against the beacon chain
    /// @param beacon The beacon roots contract reference
    /// @param proof The validator proof to verify
    /// @return valid Whether the proof is valid
    function verify(
        Proof calldata proof,
        IBeaconRoots beacon
    ) internal view returns (bool valid) {
        // Sanity check proposer index
        if (proof.proposerIndex > MAX_VALIDATOR_INDEX) {
            revert InvalidProposerIndex(proof.proposerIndex, MAX_VALIDATOR_INDEX);
        }
        
        // 1. Fetch beacon root committed via EIP‑4788
        bytes32 root = beacon.getBeaconRoot(proof.slot);
        if (root == bytes32(0)) {
            revert InvalidBeaconRoot(proof.slot);
        }

        // 2. Build leaf (we hash the 20‑byte address into 32 bytes)
        bytes32 leaf = keccak256(abi.encodePacked(bytes12(0), proof.proposerAddr));

        // 3. Check Merkle inclusion
        bool ok = MerkleProofLib.verifyProof(
            leaf,
            proof.branch,
            root
        );
        
        if (!ok) {
            revert InvalidMerkleProof();
        }

        return true;
    }
}