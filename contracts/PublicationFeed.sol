// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title PublicationFeed
/// @notice Thin blob registry that mints incremental IDs for off‑chain blobs.
///         This is intentionally generic so that the same feed can be re‑used
///         by multiple rollups.
contract PublicationFeed {
    /*//////////////////////////////////////////////////////////////
                               CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    error BlobTooLarge(uint256 size, uint256 maxSize);
    error InvalidSlotOrder(uint64 providedSlot, uint64 lastSlot);
    error InsufficientFee(uint256 provided, uint256 required);

    struct Publication {
        address publisher;
        bytes32 blobHash;   // keccak256(blob)
        uint64  slot;       // beacon‑chain slot at publication
        uint256 timestamp;  // L1 block.timestamp
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant MAX_BLOB_SIZE = 1_000_000; // 1MB limit

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    uint256 public nextId = 1;
    uint64 public lastSlot;
    uint256 public publicationFee;
    address public admin;
    mapping(uint256 => Publication) public publications;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Published(uint256 indexed id, address indexed publisher, bytes32 blobHash, uint64 slot);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor() {
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyAdmin() {
        require(msg.sender == admin, "not-admin");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Updates the publication fee
    /// @param newFee The new fee amount
    function setPublicationFee(uint256 newFee) external onlyAdmin {
        uint256 oldFee = publicationFee;
        publicationFee = newFee;
        emit FeeUpdated(oldFee, newFee);
    }

    /// @notice Transfers admin role to a new address
    /// @param newAdmin The new admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero-address");
        admin = newAdmin;
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLISH LOGIC
    //////////////////////////////////////////////////////////////*/
    /// @notice Publishes a blob and returns its unique ID
    /// @param blob The raw blob data
    /// @param slot The beacon chain slot
    /// @return id The unique publication ID
    function publish(bytes calldata blob, uint64 slot) external payable returns (uint256 id) {
        // Check blob size
        if (blob.length > MAX_BLOB_SIZE) {
            revert BlobTooLarge(blob.length, MAX_BLOB_SIZE);
        }
        
        // Check fee
        if (msg.value < publicationFee) {
            revert InsufficientFee(msg.value, publicationFee);
        }
        
        // Check slot ordering
        if (slot <= lastSlot) {
            revert InvalidSlotOrder(slot, lastSlot);
        }
        
        lastSlot = slot;
        id = nextId++;
        
        publications[id] = Publication({
            publisher: msg.sender,
            blobHash:  keccak256(blob),
            slot:      slot,
            timestamp: block.timestamp
        });
        
        emit Published(id, msg.sender, keccak256(blob), slot);
        
        // Return excess fee if any
        uint256 excess = msg.value - publicationFee;
        if (excess > 0) {
            (bool success, ) = payable(msg.sender).call{value: excess}("");
            require(success, "fee-refund-failed");
        }
    }
    
    /// @notice Withdraws accumulated fees to the admin
    function withdrawFees() external onlyAdmin {
        uint256 balance = address(this).balance;
        require(balance > 0, "no-balance");
        
        (bool success, ) = payable(admin).call{value: balance}("");
        require(success, "withdraw-failed");
    }
}